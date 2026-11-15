# Bubbles: full context

One page with everything needed to pick this project up. Details and final decisions live in `docs/PLAN.md`; the visual spec is `docs/DESIGN.md`.

## What it is

An iPhone app for events. You hold up your phone and scan the room; every nearby person who runs Bubbles gets a manga speech bubble over their head with **one sentence**: the line from their profile that matters most to *you* (e.g. their offer that answers your ask). Tap a bubble for their card (Wave / Catch). Built for a hackathon; **demo mode** is the stage fallback and must always work.

## How it works (live mode)

1. **Profile.** Onboarding: name → photo → 8 fixed spoken questions (last optional) → review lines → optional calendar plan lines. Edit any time by tapping your name chip.
2. **Photo → face signature.** Front camera, 8 frames + mirrors → MediaPipe BlazeFace finds the face → FaceNet (CoreML) → one 512-number signature. Only the signature is kept and shared; no photo is stored or sent.
3. **Bluetooth (10–30 m).** Every phone advertises service `67B45D74-F99F-4401-AF1A-6794602F3D08` and serves three readable characteristics:
   - token `DB0A724D-…8923`: 16 random bytes, rotated every 30 min, registered in Supabase for 1 h;
   - card `5C3A9E1B-…4A13`: JSON `{u: install id, n: name, l: [{k, t}]}`, ≤ 512 bytes;
   - face `E1B2C3D4-5A6B-4C7D-8E9F-0A1B2C3D4E5F`: 512 bytes int8 signature (empty without a photo).
   Phones connect, read all three, disconnect; cards are re-read every minute.
4. **Best line.** With Supabase: Edge Function `match` (viewer profile id + target token) asks Claude Haiku 5.5 via OpenRouter for the target's most useful line and a 0–100 score, cached per profile version. Without Supabase: `LocalMatch` picks a line on device from the Bluetooth card.
5. **Placement (face recognition).** Rear ARKit camera → MediaPipe BlazeFace on the full frame + overlapping zoomed tiles → FaceNet signature for the 5 largest faces → tracker keeps a running signature per face. A face gets a nearby user's bubble when cosine ≥ 0.65, it beats other faces/people by ≥ 0.10, for 3 frames in a row; it keeps the name while cosine ≥ 0.45. Not recognised → a chip ("Name nearby · looking for their face"), never a guess.

**Demo mode** (LIVE / DEMO button; simulator defaults to DEMO): bundled clip `feed.mp4`, MediaPipe faces, three demo people (`Demo.people`) pinned left to right. No recognition, no network.

## Stack

| Part | What |
| --- | --- |
| App | Swift / SwiftUI, iOS 26, xcodegen (`ios/project.yml`), bundle `com.bubbles.app.lmg7`, team `LMG7RTY598` (free account: installs last 7 days, 3 apps per device) |
| Camera | ARKit `ARWorldTrackingConfiguration` (rear); clip fallback when AR is unavailable or the camera is denied |
| Face detection | MediaPipe Tasks Vision 1.0.1 (static xcframeworks, `-ObjC` + `-force_load` graph lib), model `blaze_face_short_range.tflite` |
| Face signature | FaceNet InceptionResnetV1 (VGGFace2) converted to CoreML, 160×160 → 512-d |
| Nearby | CoreBluetooth (peripheral + central) |
| Backend | Supabase project `xflovlbpirytlyymekds` (Postgres + Edge Functions), publishable key in `Config` (`Models.swift`) |
| AI | OpenRouter, `anthropic/claude-haiku-5.5` (override with `OPENROUTER_MODEL`); 8 s timeout; canned answers on any failure |

## Code map

```
ios/Bubbles/
  Screens.swift   App root, card, caught grid, onboarding, interview (7 fixed questions), review, calendar, edit profile
  ScanView.swift  Scan screen: demoAnchors / liveAnchors (recognition), bubble layout, chips, radar
  Camera.swift    HeadTracker + HeadEngine: AR/clip frames, tiled MediaPipe detection, FaceNet signatures
  FaceID.swift    Renderer, FaceID (signature, cosine, pack/unpack), SelfieCamera + SelfieStep (photo)
  Services.swift  Backend (Supabase REST + functions), Card, Peer, BLE, LocalMatch, AppModel
  Models.swift    Config (Supabase URL/key), ProfileLine, Person, Catch, Demo people
  Theme.swift     Ink colours, Bangers font, manga panel, buttons
ios/scripts/
  sideload.py           build + install on connected phones (--list, --device, --all, --no-launch)
  fetch_mediapipe.sh    downloads MediaPipe frameworks + BlazeFace into ios/Vendor (gitignored, ~1.2 GB)
  make_facenet.sh       builds ios/Vendor/FaceNet/FaceNet.mlpackage (needs uv; convert_facenet.py)
supabase/
  migrations/0001_init.sql   profiles, profile_lines, ble_tokens, matches, waves, catches (permissive RLS)
  functions/_shared/claude.ts  askJSON via OpenRouter
  functions/match             best line + score (rubric below)
  functions/interview         fixed questions; Claude turns answers into lines
  functions/calendar_lines    events → short plan lines
mockup/   browser emulator (visual reference for bubbles/layout)
tools/    original head-tracking prototype (tracks.py)
```

## Interview (same list in `InterviewView.questions` and `supabase/functions/interview`)

1. Which branch or major are you from, and which year? → identity
2. What are you interested in? → identity
3. What are your hobbies? → identity
4. What are you up to today? → plan (expires at midnight)
5. What's a project or idea you're excited about right now? → identity
6. What could you help someone with, or teach in five minutes? → offer
7. Anything you need help with, or someone you'd like to meet? → ask
8. Anything else I should know about you? → identity (optional, can skip)

Questions are asked locally (no wait); at the end Claude writes one ≤ 60-char first-person line per answer, labelled by question (Branch & year, Interests, Hobbies, Today, Excited about, Can help with, Needs help with, More about me); templates if offline.

## Match scoring (`match` function)

Prefer a target offer that answers a viewer ask, then a target ask the viewer can help with, then shared interests. Score: 90–100 one directly solves the other's ask; 75–89 same field/project; 50–74 shared interest; 20–49 little; 0–19 nothing. Fallback (no Claude answer) = first line, score 50, not cached. Verified: aerospace PhD → physics/ML = 90; aerospace PhD → psychology = 12.

## Setup and run

```sh
# once per clone
ios/scripts/fetch_mediapipe.sh
ios/scripts/make_facenet.sh
cd ios && xcodegen generate

# build + install (Xcode at /Applications/Xcode.app; script sets DEVELOPER_DIR)
ios/scripts/sideload.py --list
ios/scripts/sideload.py --all            # or --device <UDID prefix|name>

# backend (supabase CLI 3.x, logged in, linked to xflovlbpirytlyymekds)
supabase db push --remote
supabase secrets set --env-file supabase/.env --yes     # OPENROUTER_API_KEY=… (gitignored)
supabase functions deploy --use-api --yes
```

New phone: enable Developer Mode (Settings → Privacy & Security), then after install trust the developer (Settings → General → VPN & Device Management). Locked phones can't be launched remotely.

Logs (`xcrun devicectl device process launch --console …`): `[BLE]` reads, `[NET]` Supabase calls, `[MP]` faces per frame, `[FACE]` recognition scores, `[CAM]` camera.

## Test profiles (enter via edit profile → redo interview)

- **Arjun, aerospace PhD**: satellite autonomy; offers orbital mechanics; asks for ML to estimate satellite position.
- **Meera, physics + ML**: offers PyTorch/ML for physics; asks for aerospace data. High match with Arjun.
- **Kavya, psychology**: sleep-survey study; offers study design. Low match with both.

## Decision history (short)

1. RSSI-to-face pairing → wrong people. 2. UWB (NearbyInteraction, handshake over Bluetooth) → worked only within ~1.5 m, direction rarely locked → removed (git `159d201` has it). 3. Now: face recognition against opt-in photo signatures. Apple Vision → MediaPipe for detection. Mac mini Claude proxy → OpenRouter.

## Open items

- Tune recognition thresholds from real `[FACE]` logs (walking, several people, strangers in view).
- Measure speed/heat: ~22 detection tiles + up to 5 FaceNet runs per frame.
- Face signatures go over Bluetooth unencrypted; tighten before any real launch. RLS is fully open (hackathon).
- Installs expire 7 days after sideloading (current: Sat 21 Nov); re-run `sideload.py`.
- Roll the Supabase secret key that was pasted in chat.
