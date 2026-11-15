// Body: { events: [{title, start}] }. Returns { lines: [{text, expires_at}] }. Events are not stored.
import { askJSON, json } from "../_shared/claude.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({});
  const { events = [] } = await req.json().catch(() => ({}));
  const list = events.map((e: { title: string; start: string; end?: string }) => `- ${e.title} @ ${e.start}`).join("\n");
  const ai = await askJSON<{ lines: { text: string; expires_at: string }[] }>(
    "Turn calendar events into short public 'plan' lines someone might share at an event, like 'Playing tennis Saturday morning'. " +
      "Skip private or boring ones (dentist, 1:1s). First person or activity phrasing, at most 50 characters. " +
      'Reply only JSON {"lines": [{"text": string, "expires_at": ISO8601 end of that event}]}.',
    list || "(no events)",
  );
  if (ai) return json(ai);
  return json({ lines: events.slice(0, 5).map((e: { title: string; start: string; end?: string }) => ({ text: e.title, expires_at: e.end ?? e.start })) });
});
