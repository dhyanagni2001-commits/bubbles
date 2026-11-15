// Body: { name, turns: [{q, a}] }. Returns { question } or { done: true, lines: [{kind, text}] }.
// Fixed questions (same list as InterviewView.questions in the app); Claude only writes the lines.
import { askJSON, json } from "../_shared/claude.ts";

const QUESTIONS = [
  "Which branch or major are you from, and which year?",
  "What are you interested in?",
  "What are your hobbies?",
  "What are you up to today?",
  "What's a project or idea you're excited about right now?",
  "What could you help someone with, or teach in five minutes?",
  "Anything you need help with, or someone you'd like to meet?",
  "Anything else I should know about you?",
];
// Kind of line each answer becomes. Today answers are "plan" (the app expires them at midnight).
const KINDS = ["identity", "identity", "identity", "plan", "identity", "offer", "ask", "identity"];
const TOPICS = ["Branch & year", "Interests", "Hobbies", "Today", "Excited about", "Can help with", "Needs help with", "More about me"];
const TEMPLATES = ["I'm in {}.", "I'm into {}.", "In my free time: {}.", "Today I'm {}.", "Excited about {}.", "I can help with {}.", "{}", "{}"];

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({});
  const { name, turns = [] } = await req.json().catch(() => ({}));
  if (turns.length < QUESTIONS.length) return json({ question: QUESTIONS[turns.length] });

  const qa = turns.slice(0, QUESTIONS.length).map((t: { a: string }, i: number) => `${i + 1}. [${KINDS[i]}] ${QUESTIONS[i]}\nA: ${t.a}`).join("\n");
  const ai = await askJSON<{ lines: { n: number; text: string }[] }>(
    "You turn someone's answers at a campus/tech event into short profile lines other people will see in a speech bubble. " +
      "One line per answer that has content, in the given order, tagged with its question number. Use only what they said: do not add facts, goals or adjectives they didn't give (\"CS 3rd year\" → \"CS, 3rd year.\", not \"CS, 3rd year, here to learn.\"). Each line: one first-person sentence, " +
      "at most 60 characters, specific and friendly (e.g. \"CSE, 3rd year, into robotics.\", \"Building a drone autopilot today.\"). " +
      "Skip empty or 'nothing' answers. " +
      'Reply only JSON {"lines": [{"n": question number 1-8, "text": string}]}.',
    `Name: ${name}\n${qa}`,
  );
  const fromAI = (ai?.lines ?? []).filter((l) => l.n >= 1 && l.n <= QUESTIONS.length && l.text)
    .map((l) => ({ kind: KINDS[l.n - 1], topic: TOPICS[l.n - 1], text: l.text }));
  if (fromAI.length) return json({ done: true, lines: fromAI });
  const lines = turns.slice(0, QUESTIONS.length).flatMap((t: { a: string }, i: number) => {
    const a = (t.a ?? "").trim().replace(/[.!]+$/, "");
    return a ? [{ kind: KINDS[i], topic: TOPICS[i], text: TEMPLATES[i].replace("{}", a).slice(0, 90) }] : [];
  });
  return json({ done: true, lines });
});
