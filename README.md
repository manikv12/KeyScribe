# KeyScribe

KeyScribe is a macOS menu-bar dictation app that transcribes speech and inserts the result into the currently focused text field.

The app runs as a menu bar utility (`LSUIElement`), so it does not show a Dock icon.

## What the app does

- Captures speech using Apple Speech (`SFSpeechRecognizer`) and microphone input.
- Cleans transcript text before insert (spacing, punctuation, capitalization, duplicate-word cleanup).
- Inserts text into the active app with reliability fallbacks.
- Stores the last 20 transcripts in local history.
- Lets you paste the most recent transcript with `⌥⌘V` without needing to copy from history first.

## How insertion works

When a transcript is finalized (or when you trigger paste-last), KeyScribe uses this insertion flow:

1. Attempt direct Accessibility text insertion only when explicitly enabled for compatibility testing.
2. If clipboard copy mode is ON:
   write to system clipboard, send paste shortcut, then fall back to typed unicode events if needed.
3. If clipboard copy mode is OFF (default privacy mode):
   use transient clipboard metadata, send paste shortcut, restore prior clipboard contents, then fall back to typed unicode events if needed.

This keeps normal dictation out of persistent clipboard history when privacy mode is enabled.

## Controls and shortcuts

- Menu item toggles continuous dictation:
  - `Start Continuous Dictation`
  - `Stop Continuous Dictation`
- Hold-to-talk shortcut is always active for quick burst dictation (default `⌥⌘Space`).
- Continuous toggle shortcut is always active for session dictation (default `⌃⌥⌘Space`).
- While continuous dictation is running, hold-to-talk input is ignored.
- Paste last transcript: `⌥⌘V` (also available in the menu as **Paste Last Transcript**).

## Status

KeyScribe is a fully functional macOS transcription assistant ready for daily use:

- Default hold-to-talk shortcut: **⌥⌘Space** (customizable in Settings)
- Default continuous toggle shortcut: **⌃⌥⌘Space** (customizable in Settings)
- Requires **Accessibility**, **Microphone**, and **Speech Recognition** permissions (prompted on first launch)
- Tested on macOS 13 (Ventura) and later

### Reset Accessibility permission (dev/testing)

If you are testing permission flows and want to force macOS to ask again:

```bash
sudo tccutil reset Accessibility com.keyscribe.KeyScribe
```

## Distribution

KeyScribe can be distributed as a drag-and-drop DMG installer.

### For trusted testers (ad-hoc signed)

The default `./build.sh` produces an ad-hoc signed app. Recipients will need to
right-click → Open the first time to bypass Gatekeeper.

### For public distribution (Developer ID signed + notarized)

Set your Developer ID credentials, then build and notarize:

```bash
export DEVELOPER_ID="Your Name (TEAMID)"
./build.sh
Scripts/notarize.sh
```

This produces a notarized DMG that opens without Gatekeeper warnings on any Mac.

## Privacy model

- `Also copy transcript to system clipboard` is OFF by default.
- With this OFF setting, KeyScribe still pastes reliably via transient clipboard flow and history, but avoids permanently pushing dictation text into clipboard managers when possible.
- Explicit copy actions from History always copy to system clipboard by design.

## Build and install

Build app + drag-and-drop DMG:

```bash
./build.sh
```

Output artifacts:

- `dist/KeyScribe.app`
- `dist/KeyScribe.dmg` (contains `KeyScribe.app` + `Applications` alias for drag-and-drop install)

Optional build flags:

- `./build.sh --install` installs directly to `/Applications`
- `./build.sh --no-dmg` skips DMG generation

Run app directly:

```bash
open dist/KeyScribe.app
```

Open installer DMG:

```bash
open dist/KeyScribe.dmg
```

## Diagnostics and reliability testing

Enable insertion diagnostics:

- Settings -> General -> `Enable insertion diagnostics (developer)`
- or environment variable: `KEYSCRIBE_INSERTION_DIAGNOSTICS=1`

Optional custom log path:

- `KEYSCRIBE_INSERTION_DIAGNOSTICS_PATH=/tmp/my-keyscribe-diag.log`

Default diagnostics log:

- `/tmp/keyscribe-insertion-diagnostics.log`

Run smoke/regression suite:

```bash
Scripts/run-tests.sh
```

Run insertion decision regression only:

```bash
Scripts/run-insertion-reliability.sh --regression
```

## Project structure

- `Package.swift` - Swift package entry
- `Sources/KeyScribe/App.swift` - app lifecycle, status menu, permission flow, icon state, insertion orchestration
- `Sources/KeyScribe/Services/SpeechTranscriber.swift` - speech capture + recognition pipeline
- `Sources/KeyScribe/Services/TextInserter.swift` - insertion engine and paste/typing fallbacks
- `Sources/KeyScribe/Services/HotkeyManager.swift` - hold-to-talk and one-shot hotkeys
- `Sources/KeyScribe/Services/TranscriptHistoryStore.swift` - local transcript history persistence
- `Resources/Info.plist` - app metadata and permission keys
