# CLAUDE.md — taos-dictate (iOS)

Native iPhone app for **TAOS Dictate**: speak, get clean text back in a chosen style (Formal, Professional, Conversational, Casual), same language or translated. Plus **Decoder**: paste a messy message, get it cleaned up and translated. Rung 2 of the Dictate plan (rung 1 = web `/dictate` on taoslite.com, PR #145 in `xdrabbit/taos-lite`).

Owner: Tom Ashby. Primary first user: Liz (iPhone, Spanish speaker, types fast with her fingers — the app has to beat that). Product line: *"You don't fall in love in sentences, you fall in love in stories."* Long-form and timely matter more than gimmicks.

## Ground rules

- **Verified answers only.** Never invent Apple APIs, entitlement keys, Info.plist keys, file paths or config. If unsure, look it up in Apple's docs or say so.
- **No AI/speech code in the app.** All transcription, rewriting and translation happen on the TAOS backend (`https://taoslite.com/api/dictate`). The app records audio, sends it, shows results. One prompt fix on the server fixes web and app together.
- **No secrets in the repo.** The Supabase URL and publishable (anon) key are public by design; nothing else. No OpenAI keys, ever.
- **Ask Tom before**: changing bundle IDs, signing team, App Store Connect records, or anything that costs money.
- Commit small, open PRs, don't push to `main` without Tom's go.

## Platform facts (verified 2026-11-27)

- **iOS keyboard extensions cannot use the microphone.** Apple has disallowed mic access for app extensions since 2014. Dictation apps (Wispr Flow etc.) record in the containing app instead.
- There is **no clean public API** for the containing app to send the user back to the host app (WhatsApp/Messages) after recording; developers are still asking Apple about it. Don't build on private APIs.
- Building requires Xcode on a Mac → this repo lives and builds on **Ada** (M4 Mac mini). Blackbird (Linux) can't build it.

## Scope — rung 2 (this repo, first version)

1. **Main app (SwiftUI)**
   - Sign in with the existing TAOS account (Supabase Auth, same project as taoslite.com). Magic-link / email OTP to start; Sign in with Apple later if wanted. Store the session in the Keychain; refresh tokens properly.
   - **Speak** screen: one big tap-to-toggle mic (tap to start, tap to stop — same as TAOS home), live timer, up to **10 minutes** with a visible countdown and hard stop (server handles chunking — follow the API contract). Style pills and output language; changing either re-styles the same transcript without re-recording.
   - **Decoder** screen: paste box + Paste button → cleaned original + faithful translation + brief ambiguity notes.
   - Big **Copy** and **Share** (system share sheet). Remember last style/language/mode on device.
   - Bilingual UI (English/Spanish), following the device language. Spanish strings get Liz's review.
   - Clear "Nothing was heard — try again / No se escuchó nada" handling for HTTP 422.
2. **TAOS keyboard (custom keyboard extension), no microphone**
   - Shares the latest result with the app via an **App Group**.
   - Shows an **Insert** key that types the last dictation into the current field, a button to open the TAOS app to dictate, and the basics (globe/next-keyboard, delete, return, space). It is not trying to be a full typing keyboard in v1.
   - Explain Full Access honestly if it's needed (App Group read may not need it — verify).
3. **Not in rung 2:** recording from inside the keyboard / auto-return to the host app (rung 3), Mac app, payments, metering.

## Backend contract

Source of truth: **`docs/dictate/CLAUDE.md` → "API contract"** in `xdrabbit/taos-lite` (being finalized on PR #145). Summary of what to expect:

- `POST https://taoslite.com/api/dictate` with `Authorization: Bearer <Supabase access token>`.
- Speak: multipart audio upload (chunked for long recordings per the contract) → `{ text, ... }`.
- Restyle and Decoder: JSON requests on the same route, no audio.
- Gate is founders-only for now: non-founder → 404, missing/invalid token → 401, silence → 422, too large → 413, rate/spend limit → 429. Re-read the contract before implementing the networking layer; don't guess field names.

## Getting started (Tom, on Ada)

1. Create a private GitHub repo `xdrabbit/taos-dictate`, clone it on Ada, drop this file in as `CLAUDE.md`.
2. Run Claude Code in that folder. First task: create the Xcode project (SwiftUI app + keyboard extension target + shared App Group), bundle IDs and signing team chosen by Tom, then a sign-in screen against Supabase.
3. Install on Tom's iPhone from Xcode first. TestFlight for Liz once the speak → copy loop works.

## Definition of done for rung 2

Liz dictates a WhatsApp message in Spanish, taps Copy (or uses the TAOS keyboard's Insert), and sends it — faster than she'd type it. Tom pastes one of Liz's messages into Decoder and understands it without a decoder ring.