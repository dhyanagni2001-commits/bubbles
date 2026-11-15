# Bubbles: start here

You are building the Bubbles iPhone app on a machine with Xcode. The planning machine had no Xcode, so nothing in `ios/` exists yet.

Read these in order before writing code:
1. `docs/PLAN.md`: product, final decisions, architecture, data model, build order, open items.
2. `docs/DESIGN.md`: the Manga visual spec.
3. `mockup/index.html` (open in Chrome): the working visual reference. Bubble placement, collision layout and animations in `mockup/app.js` are the behaviour to port to SwiftUI.

Rules:
- Decisions in `docs/PLAN.md` are final. Do not swap the stack (no PWA, no Unity, live placement is face recognition against each user's own opt-in photo signature, UWB as backup). Ask the owner before changing hosting, database or framework choices.
- One sentence per bubble, always.
- Keep demo mode working at every step; it is the stage fallback.
- Claude goes through OpenRouter (`OPENROUTER_API_KEY` secret); without a key the functions return canned answers.
- Commits: no Claude co-author line.
- Update `docs/PLAN.md` when a decision changes, and record shipped work there. Do not record rejected explorations.
