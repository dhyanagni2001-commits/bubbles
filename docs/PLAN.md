# Bubbles: build plan

Status: decisions final as of 2026-11-14. Hackathon deadline 2026-11-15, 11:00. Built as a native iPhone app on a separate machine with Xcode (the planning Mac has no Xcode).

## The product in one paragraph

You hold up your iPhone and scan the room, Pokemon Go style. Every person nearby who runs Bubbles gets a manga speech bubble over their head with one sentence: the line from their profile that matters most to you. If you are a grad student and they are a freshman, the bubble says "How would I add a Redis cache to my project?". If you want to get into aerospace and they are a researcher, it says "I'm an aerospace researcher working on satellite autonomy.". A person walking by gives you 2 to 3 seconds to read, so the bubble must appear fast and say exactly one sentence. Phones find each other over Bluetooth. Each user takes a photo at setup; the phone turns it into a face signature and shares only that over Bluetooth. The scanning phone recognises nearby users' faces against those signatures and puts the bubble on the right face, at walking distance. The phone is the first device; AR glasses come later and are out of scope.

## Hard rules

1. One sentence per bubble. No second line, no list. A small badge (% match) is allowed.
2. Bubble visible within 1 second of a face entering the frame. Matching runs before the person is in view (see Latency).
3. Placement is face recognition against opt-in photos: each user takes a photo at setup, FaceNet turns it into a 512-number signature, and only the signature is shared over Bluetooth. MediaPipe BlazeFace finds faces, FaceNet signs them, and the bubble goes on the face matching a nearby user's signature. Users without a photo get a status chip, never a guessed face. Matching is on device, only against people whose phones are nearby. (Changed 2026-11-14 at the owner's request: UWB only located people within ~1.5 m and was removed.)
4. Visual style is Manga. Spec in [DESIGN.md](DESIGN.md). Reference implementation in `mockup/` (open `mockup/index.html` in Chrome, Manga is the default preset).
5. iOS 26 only. Swift, SwiftUI, ARKit, MediaPipe Tasks Vision, CoreML (FaceNet), CoreBluetooth.
6. Demo mode must exist so the stage demo cannot fail.

## Decisions

| Area | Decision |
|---|---|
| Platform | Native iPhone app, iOS 26 minimum, Swift + SwiftUI. Not a PWA (iOS Safari has no Web Bluetooth). |
| Camera | ARKit `ARWorldTrackingConfiguration`, rear camera. Faces found with MediaPipe BlazeFace on each `ARFrame` (overlapping zoomed tiles so faces across a room are found). |
| Identity | CoreBluetooth. Each app advertises a service and serves a rotating token. Works with the other phone in background. |
| Head to person | RSSI ranking: strongest Bluetooth signal goes to the largest face. |
| Backend | Supabase: Postgres, Realtime, Edge Functions. |
| Matching AI | Claude Haiku (`anthropic/claude-haiku-5.5`) through OpenRouter from Supabase Edge Functions, with `OPENROUTER_API_KEY` (model overridable with `OPENROUTER_MODEL`); canned answers without a key. (Changed 2026-11-14 at the owner's request: OpenRouter replaces the Mac mini proxy.) |
| Onboarding | Name, then a spoken AI interview, then review and approve lines. |
| Profile lines | Five kinds: ask, offer, identity, looking_for, plan (plan comes from calendar). |
| Calendar | Read with EventKit, Claude (through OpenRouter) suggests "plan" lines, user approves each. No on-device models (too slow). |
| Tap a bubble | Opens their card, with Wave and Catch buttons. |
| Waves | In app only, polled from the `waves` table every 4 s while the app is open. No push (free Apple account cannot use APNs). |
| Game layer | Manga % match badge, rarity tiers, Caught collection. No XP or levels. |
| Distribution | Free Apple account, Xcode sideload by cable. Apps expire after 7 days, max 3 apps per device. |

## Architecture

```
 iPhone A (scanning)                          iPhone B (in pocket, app backgrounded)
 ARKit camera + MediaPipe faces                 CBPeripheralManager advertises SERVICE_UUID
 CBCentralManager scans SERVICE_UUID  ──BLE──> GATT read: TOKEN characteristic (16 bytes)
        │ token + RSSI
        ▼
 Supabase Edge Function `match`  ──> profiles, ble_tokens, matches tables
        │ (cache miss) ──> OpenRouter (Claude Haiku) ──> sentence, kind, score
        ▼
 Bubble { sentence, score, rarity } pinned to the face ranked by RSSI
```

### Bluetooth

- Service UUID: `67B45D74-F99F-4401-AF1A-6794602F3D08`
- Token characteristic UUID: `DB0A724D-9CD5-4E63-8212-F493554F8923` (read only)
- Peripheral side: `CBPeripheralManager` advertises `[SERVICE_UUID]`. Characteristic value is the current token. Token is 16 random bytes, registered in `ble_tokens` with a 1 hour expiry, rotated every 30 minutes.
- Central side: `CBCentralManager.scanForPeripherals(withServices: [SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])` while the scan screen is open. Scanning must filter by the service UUID, because a backgrounded iOS peripheral moves its UUID into the overflow area, which only filtered scans can see.
- Card characteristic UUID: `5C3A9E1B-2F4D-4B8A-9C61-7E2D0F8B4A13` (read only): the public profile as compact JSON `{u, n, l: [{k, t}]}`, at most 512 bytes. It lets two phones show each other with no backend, and is the fallback when the backend or Claude fails (best line picked on device by kind and word overlap).
- NI characteristic UUID: `A7F3C2D1-6B4E-4F8A-B5D9-2C1E0F7A3B64` (read + write): Ultra Wideband handshake. The phone with the smaller install id writes `[uid length][uid][zlib(NIDiscoveryToken archive)]`, then reads back the other phone's token made for it (served per central). One `NISession` per peer, with camera assistance sharing the scan screen's ARSession, so each phone's position comes back in AR world space. Retried on each card re-read until a position arrives; dropped when the peer leaves.
- On a new peripheral: connect (10 s timeout, exponential backoff on failure), read token and card, disconnect. Cache `peripheral.identifier -> token`. Re-read all peers after each token rotation. Keep scanning to update RSSI (smooth with an exponential moving average, alpha 0.3; restart the average after a 5 s gap).
- iOS rotates Bluetooth addresses, so one person can appear under several identifiers. Peers are merged by card install id before anything is shown.
- Match calls retry up to 6 times with growing delay (the other phone may not have registered its token yet). Profile sync and token registration retry in the background; onboarding never waits on the network.
- Info.plist: `UIBackgroundModes` = `bluetooth-central`, `bluetooth-peripheral`. `NSBluetoothAlwaysUsageDescription`, `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSCalendarsFullAccessUsageDescription`.
- Only consider peers with smoothed RSSI above -85 dBm.

### Camera and placement (live mode: face recognition)

- `ARSession` with `ARWorldTrackingConfiguration` (gravity aligned) drives the rear camera.
- MediaPipe (`MediaPipeTasksVision` xcframeworks from `ios/scripts/fetch_mediapipe.sh`, model `blaze_face_short_range.tflite` in Resources) finds faces on the full frame plus overlapping zoomed tiles, so faces across a room are found.
- Photo: onboarding step (and "📷 PHOTO" / edit profile) averages 8 front-camera frames plus mirrors into one signature, stored as `face` in UserDefaults. No image is kept.
- FaceNet (`ios/Vendor/FaceNet/FaceNet.mlpackage`, built by `ios/scripts/make_facenet.sh`) signs the 5 largest faces per frame from full-resolution crops; each head track keeps a running average.
- Recognition (`ScanView.liveAnchors`): cosine ≥ 0.65, at least 0.10 above both that person's other faces and that face's other people, for 3 frames in a row. A recognised track keeps its name while cosine stays ≥ 0.45. Scores are logged as `[FACE]` once a second for tuning.
- Not recognised: a chip ("Name nearby · looking for their face" / "no photo yet"), never a guessed face.
- Face characteristic `E1B2C3D4-5A6B-4C7D-8E9F-0A1B2C3D4E5F`: 512 bytes, int8 signature, empty when no photo.
- Collision layout and smoothing as in `mockup/app.js`.

### Demo mode placement

- The bundled clip (or the live camera) with MediaPipe face detection, a nearest-neighbour head tracker ported from `tools/tracks.py`, and the three demo people pinned left to right.

### Latency

The 1 second budget works because matching happens when Bluetooth first hears someone, typically 10+ meters away and several seconds before they are in the camera. The `match` result is cached in `matches` per (viewer, target, profile versions). Once in view, the bubble only needs local data. Show the scanning dots for 0.35 s on first appearance, then the sentence.

### Matching

Edge Function `match(viewer_id, token)`:
1. Resolve token to `target_id` via `ble_tokens`.
2. Return cached row from `matches` if both profile versions are unchanged.
3. Otherwise call Claude Haiku through OpenRouter with both profiles' public lines. Prompt: pick the single line of the target most useful to the viewer; may tighten wording to at most 60 characters; keep first person; return JSON `{ "sentence": string, "kind": "ask|offer|identity|looking_for|plan", "score": 0-100 }`.
4. Store and return `{ target_id, name, sentence, kind, score, rarity }`.

Rarity from score: 90 and up is Legendary, 75 to 89 is Rare, below 75 is Common.

### Data model (Supabase)

```sql
create table profiles (
  id uuid primary key default gen_random_uuid(),
  device_id text unique not null,
  name text not null,
  avatar_url text,
  version int not null default 1,
  updated_at timestamptz default now()
);
create table profile_lines (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid references profiles on delete cascade,
  kind text check (kind in ('ask','offer','identity','looking_for','plan')),
  text text not null,
  source text check (source in ('interview','calendar','manual')),
  expires_at timestamptz,          -- calendar lines expire after the event
  is_public boolean default true
);
create table ble_tokens (
  token text primary key,          -- hex of the 16 byte token
  profile_id uuid references profiles on delete cascade,
  expires_at timestamptz not null
);
create table matches (
  viewer_id uuid, target_id uuid,
  viewer_version int, target_version int,
  sentence text, kind text, score int,
  created_at timestamptz default now(),
  primary key (viewer_id, target_id)
);
create table waves (
  id uuid primary key default gen_random_uuid(),
  from_id uuid, to_id uuid, sentence text,
  created_at timestamptz default now(), seen_at timestamptz
);
create table catches (
  owner_id uuid, target_id uuid, sentence text, score int, rarity text,
  created_at timestamptz default now(),
  primary key (owner_id, target_id)
);
```

Identity is a random install ID stored in UserDefaults (sent as `device_id`), no login. Row level security can stay permissive for the hackathon; tighten later.

### Onboarding: voice interview

1. Type your name.
2. Photo (face signature, skippable), then a fixed interview of 8 questions (owner's list, 2026-11-14): branch/major and year; interests; hobbies; what are you up to today; a project or idea you're excited about; what you could help with or teach in five minutes; anything you need help with or someone to meet; anything else I should know about you (optional). Spoken with `AVSpeechSynthesizer`, answered by voice (`SFSpeechRecognizer`) or typing. Questions are asked locally with no network wait; at the end Edge Function `interview` has Claude turn the answers into one line each (identity, identity, identity, plan, identity, offer, ask), with templates as fallback. The "today" plan line expires at midnight. The same list lives in `InterviewView.questions` and `supabase/functions/interview`.
2b. Edit profile: tap the name chip on the scan screen to edit name and lines, retake the photo or redo the interview.
3. Review screen: each draft line is editable and removable. Save writes `profiles` and `profile_lines`.
4. Calendar step (optional): EventKit full access, next 7 days. The app sends event titles and times to Edge Function `calendar_lines`, which asks Claude to turn them into short plan lines like "Playing tennis Saturday morning". Event data is not stored. The user ticks which lines go public; only approved lines are saved. Do not use Apple on-device models (Foundation Models) anywhere; they are too slow.

### Screens

1. **Onboarding**: name, voice interview, review lines, calendar suggestions.
2. **Scan** (home): camera, Manga bubbles, my profile chip (top left), scan pill (bottom left, "2 in view, 4 nearby"), radar (bottom right; blips from Bluetooth, lit when that person has a bubble).
3. **Card**: tap a bubble. Full manga profile card with all their public lines, the % match badge, rarity, and Wave and Catch buttons.
4. **Caught**: Pokedex style grid of people you caught, with the sentence and rarity at catch time.
5. **Wave toast**: Realtime insert on `waves` for me shows "[Name] waved: [sentence]".
6. **Demo mode**: hidden toggle, long press the profile chip for 2 seconds.

### Demo mode

Seeded profiles assigned to faces left to right, no Bluetooth or network needed:
1. "I'm an aerospace researcher working on satellite autonomy." 94%, Legendary
2. "How would I add a Redis cache to my project?" 81%, Rare
3. "Need a teammate who knows ARKit, demo is tomorrow." 67%, Common

## Build order

Each step ends in something demoable. Stop and polish if time runs short.

1. Xcode project `Bubbles`, iOS 26, SwiftUI. Bundle the Bangers font. Scan screen: ARKit camera, MediaPipe faces, Manga bubbles with demo mode data. This alone is the demo floor.
2. Radar, profile chip, scan pill, collision layout, entrance animations, matching the mockup.
3. Supabase project, tables above, `match` Edge Function with a stub answer, then the real Claude call through OpenRouter.
4. Bluetooth: peripheral advertising plus token, central scanning plus RSSI, RSSI to head assignment.
5. Onboarding: name and review screen first (typed lines), then the voice interview on top.
6. Card, Wave over Realtime, Caught collection.
7. Calendar plan lines.

## Repo layout

```
docs/       PLAN.md (this file), DESIGN.md (Manga spec)
mockup/     browser emulator, the visual reference; open index.html
tools/      offline head tracking used for the mockup clip (Swift + Python)
ios/        Xcode project (to be created on the build machine)
supabase/   migrations and edge functions (to be created)
```

## Shipped (2026-11-14)

All seven build steps are in code. `ios/` (xcodegen `project.yml`, SwiftUI) and `supabase/` (migration + `match`, `interview`, `calendar_lines` functions).
- Scan screen: ARKit camera, MediaPipe faces, tracker ported from `tools/tracks.py`, Manga bubbles with balanced wrapping, scanning dots, slam-in, badge pop, crowded layout, stems, radar, scan pill, profile chip.
- Without ARKit (simulator) the scan screen plays the bundled mockup clip and runs the same MediaPipe pipeline on it.
- Demo mode: a visible LIVE / DEMO switch under the profile chip (long press on the chip still works). The choice is remembered; real phones start in LIVE, the simulator in DEMO. Live mode shows a Bluetooth readout (advertising, scanning, phones heard, card reads).
- Bluetooth peripheral + central, rotating token, RSSI EMA; reads token, card and face signature from each phone.
- Onboarding (name, spoken interview or typed lines, review, calendar plan lines), card with Wave/Catch, Caught grid, wave toast.
- Hackathon hardening: Bluetooth card fallback (works with no backend), peer de-duplication, connect timeouts and retries, screen kept awake while scanning, camera denied/failed falls back to the demo clip with a note in the scan pill, Bluetooth off/denied shown in the pill, one-sentence enforcement on every line, interview capped at 6 questions, mic double-tap crash fixed, edge functions return canned answers when Claude errors.
- `ios/scripts/sideload.py`: build and install on any connected phone, see Run and deploy.
- Face-recognition placement (MediaPipe + FaceNet against opt-in photo signatures over Bluetooth), photo step, profile editing, fixed 7-question interview, Supabase live (OpenRouter Claude Haiku 5.5, match scoring rubric). UWB was tried and removed (see git history 159d201).

## Run and deploy

1. iOS: `cd ios && xcodegen generate && open Bubbles.xcodeproj`, pick your personal team in Signing, run on device.
   To put it on any connected phone (yours or a friend's) without opening Xcode: `ios/scripts/sideload.py` (`--list`, `--device <UDID prefix>`, `--all --exclude <yours>`, `--replace`). It handles pairing, Developer Mode, iOS version, device registration, the 3-app and 7-day free-account limits and the Trust step.
2. Supabase: `supabase link --project-ref <ref>`, `supabase db push`, `supabase functions deploy match interview calendar_lines`.
3. Secrets: put `OPENROUTER_API_KEY=...` in `supabase/.env` (gitignored), then `supabase secrets set --env-file supabase/.env`.
4. Put the project URL and anon key in `Config` at the top of `ios/Bubbles/Models.swift`.

## Open items

1. Supabase project and GitHub repo do not exist yet. The owner creates them and pushes the repo.
2. Bluetooth verified between two iPhone 16 Pros (2026-11-14): each advertises, hears the other at about -57 dBm and reads its card. Bubble placement on real faces with two phones still to rehearse. Edge functions not type-checked (no Deno on the build Mac).
