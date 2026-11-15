import { createClient } from "npm:@supabase/supabase-js@2";
import { askJSON, json } from "../_shared/claude.ts";

const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const rarity = (s: number) => (s >= 90 ? "Legendary" : s >= 75 ? "Rare" : "Common");

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({});
  const { viewer_id, token } = await req.json().catch(() => ({}));
  if (!viewer_id || !token) return json({ error: "viewer_id and token required" }, 400);
  const { data: tok } = await db.from("ble_tokens").select("profile_id")
    .eq("token", token).gt("expires_at", new Date().toISOString()).maybeSingle();
  if (!tok) return json({ error: "unknown token" }, 404);
  const target_id = tok.profile_id;

  const load = async (id: string) => {
    const { data: p } = await db.from("profiles").select("id,name,version").eq("id", id).maybeSingle();
    if (!p) return null;
    const { data: lines } = await db.from("profile_lines").select("kind,text,expires_at")
      .eq("profile_id", id).eq("is_public", true);
    const now = Date.now();
    return { ...p, lines: (lines ?? []).filter((l) => !l.expires_at || Date.parse(l.expires_at) > now) };
  };
  const [viewerRow, target] = await Promise.all([load(viewer_id), load(target_id)]);
  if (!target) return json({ error: "unknown target" }, 404);
  // A viewer whose profile has not synced yet still gets a bubble (version 0 never hits the cache).
  const viewer = viewerRow ?? { id: viewer_id, name: "Someone", version: 0, lines: [] };

  const { data: cached } = await db.from("matches").select("*")
    .eq("viewer_id", viewer_id).eq("target_id", target_id).maybeSingle();
  if (cached && cached.viewer_version === viewer.version && cached.target_version === target.version) {
    return json({ target_id, name: target.name, sentence: cached.sentence, kind: cached.kind, score: cached.score, rarity: rarity(cached.score), lines: target.lines });
  }

  const fmt = (p: { lines: { kind: string; text: string }[] }) => p.lines.map((l: { kind: string; text: string }) => `- [${l.kind}] ${l.text}`).join("\n");
  const ai = await askJSON<{ sentence: string; kind: string; score: number }>(
    "You match people at a campus/tech event. Pick the single line of the TARGET that is most useful to the VIEWER " +
      "(prefer a TARGET offer that answers a VIEWER ask, then a TARGET ask the VIEWER can help with, then shared interests). " +
      "You may tighten its wording to at most 60 characters; keep it first person and one sentence. " +
      "Score how useful meeting is for the VIEWER: 90-100 one directly solves the other's ask; 75-89 same field or project with clear " +
      "overlap; 50-74 some shared interest or hobby; 20-49 little in common; 0-19 nothing. " +
      'Reply with only JSON: {"sentence": string, "kind": "ask|offer|identity|looking_for|plan", "score": 0-100}.',
    `VIEWER (${viewer.name}):\n${fmt(viewer)}\n\nTARGET (${target.name}):\n${fmt(target)}`,
  );
  const first = target.lines[0] ?? { text: `Hi, I'm ${target.name}.`, kind: "identity" };
  // No Claude answer: neutral score, and don't cache it so the next request asks again.
  const r = ai ?? { sentence: first.text, kind: first.kind, score: 50 };
  r.score = Math.max(0, Math.min(100, Math.round(Number(r.score) || 50)));
  if (!r.sentence) r.sentence = first.text;

  if (!ai) console.error("match: no AI answer, fallback used", { viewer: viewer.lines.length, target: target.lines.length });
  if (viewerRow && ai) await db.from("matches").upsert({
    viewer_id, target_id, viewer_version: viewer.version, target_version: target.version,
    sentence: r.sentence, kind: r.kind, score: r.score,
  });
  return json({ target_id, name: target.name, ...r, rarity: rarity(r.score), lines: target.lines });
});
