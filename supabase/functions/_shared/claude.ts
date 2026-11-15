// Claude Haiku via OpenRouter (OpenAI-style chat completions over fetch, no SDK).
// Needs OPENROUTER_API_KEY; OPENROUTER_MODEL overrides the model. With no key, callers get null
// and use canned answers.
const key = Deno.env.get("OPENROUTER_API_KEY");
const model = Deno.env.get("OPENROUTER_MODEL") ?? "anthropic/claude-haiku-5.5";

// Any failure (network, rate limit, bad JSON, refusal) returns null so callers fall back to
// canned answers instead of erroring; a bubble must still appear on stage.
export async function askJSON<T>(system: string, user: string): Promise<T | null> {
  if (!key) return null;
  try {
    const r = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "X-Title": "Bubbles" },
      body: JSON.stringify({
        model,
        max_tokens: 2048,
        messages: [{ role: "system", content: system }, { role: "user", content: user }],
      }),
      signal: AbortSignal.timeout(8_000),
    });
    if (!r.ok) { console.error("openrouter", r.status, (await r.text()).slice(0, 300)); return null; }
    const j = await r.json();
    const text: string = j?.choices?.[0]?.message?.content ?? "";
    const m = text.match(/\{[\s\S]*\}/);
    return m ? (JSON.parse(m[0]) as T) : null;
  } catch (e) {
    console.error("openrouter failed:", e instanceof Error ? e.message : e);
    return null;
  }
}

export const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
export const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
