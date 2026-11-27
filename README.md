# TAOS Dictate (iOS)

Native iPhone app for TAOS Dictate + Decoder. See `CLAUDE.md` for scope and rules.
All speech/AI work happens on `https://taoslite.com/api/dictate`. The app only records, uploads and shows results.

## Build

```sh
brew install xcodegen      # once
xcodegen generate          # after changing project.yml or adding/removing files
open TaosDictate.xcodeproj
```

- Targets: `TaosDictate` (app, `com.taoslite.dictate`) and `TaosKeyboard` (keyboard extension, `com.taoslite.dictate.keyboard`), sharing App Group `group.com.taoslite.dictate`.
- **Signing:** `DEVELOPMENT_TEAM` is blank. Pick the team in Xcode › Signing & Capabilities for both targets (or set it in `project.yml`). Automatic signing registers the bundle IDs and App Group.
- Simulator layout check without signing in: run with the launch argument `-uiPreview` (DEBUG builds only).

## Layout

| path | what |
|---|---|
| `App/Services/DictateAPI.swift` | the API contract: speak, chunked speak, re-style, decode, error mapping, retry rules |
| `App/Services/ChunkedRecorder.swift` | AAC 32 kbps mono, 4.5-min chunks, 10:00 hard stop, stops on interruption |
| `App/Services/SpeakModel.swift` | Speak flow: uploads earlier chunks while still recording, sends `prior` with the last |
| `App/Services/AuthManager.swift` | Supabase email-code sign-in, Keychain session, refresh on 401 |
| `App/Views/` | Sign-in, Speak, Decoder, Settings |
| `Keyboard/KeyboardViewController.swift` | Insert / Dictate / globe / space / delete / return |
| `Shared/` | config, App Group store, en/es strings (Spanish marked *pendiente de revisión por Liz*) |

## Keyboard & Full Access

The keyboard sets `RequestsOpenAccess = true`. Apple's custom keyboard guide lists the shared container with the containing app as available only with open access. Without it the keyboard can't read the last dictation, and it says so on screen. The keyboard has no network code and no microphone.

The **Dictate** key opens the app by walking the responder chain to `UIApplication` and calling the public `open(_:options:)`. Keyboards have no supported API for this. If iOS blocks it, the keyboard tells the user to open the app themselves.
