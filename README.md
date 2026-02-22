# KeyScribe

A macOS menu-bar transcription assistant: hold a keyboard shortcut to record speech and automatically insert the text into the current focused app.

**Name idea:** **KeyScribe** (“speak with a key press, write with your voice”).

## What’s included
- SwiftUI + AppKit starter app structure
- Menu-bar app that runs in the background
- Hold-to-talk behavior:
  - **start recording on key-down**
  - **stop on key-up**
- Speech transcription with Apple Speech framework
- Smart cleanup pipeline before insertion:
  - **Light** mode (safe spacing/punctuation/duplicate-word cleanup)
  - **Aggressive** mode (stronger normalization + sentence capitalization)
- Transcript History panel:
  - stores last 20 dictations with timestamp
  - quick actions for **Copy** and **Re-insert**
- Paste-injection workflow (copies transcript to clipboard then sends `⌘V`)
- Uses macOS inbuilt speech recognition (`SFSpeechRecognizer`) with
  on-device preference (`requiresOnDeviceRecognition = true` when available)
- Enables Apple automatic punctuation (`addsPunctuation`) by default for cleaner sentence output
- Lower default finalization delay (250ms) for reduced perceived latency

## Status
This is a functional scaffold, not a finished product yet:
- hotkey handling is implemented for a default shortcut
  **⌥⌘Space**
- global event monitoring may need Accessibility permissions depending on macOS version
- in macOS sandboxed/bundled environments, permissions and key capture behavior can vary

## Planned app behavior
1. User holds the configured key combo.
2. App records and transcribes speech in near-real-time.
3. User releases the key combo.
4. Final transcript is inserted into the active text field.

## Project layout
- `Package.swift` – local Swift package scaffold
- `Sources/KeyScribe/App.swift` – app bootstrap + status/menu
- `Sources/KeyScribe/Services/`
  - `SpeechTranscriber.swift` – mic + speech recognition
  - `HotkeyManager.swift` – global hold shortcut tracking
  - `TextInserter.swift` – paste last transcript into active field
- `Resources/Info.plist` – permission strings

## Quick run
1. Open this folder in Xcode (or convert to your preferred Xcode project style),
   then run on macOS.
2. Grant **Microphone** and **Speech Recognition** permissions.
3. Keep app running.
4. Hold **⌥⌘Space** to dictate, release to insert.

## Copy/paste reliability diagnostics
When debugging transcribe → clipboard → paste behavior, use the lightweight insertion diagnostics mode.

### Enable diagnostics
Use either option:
- **Settings → General → "Enable insertion diagnostics (developer)"**
- or environment flag: `KEYSCRIBE_INSERTION_DIAGNOSTICS=1`

Optional log path override:
- `KEYSCRIBE_INSERTION_DIAGNOSTICS_PATH=/tmp/my-keyscribe-diag.log`

Default log path:
- `/tmp/keyscribe-insertion-diagnostics.log`

Diagnostics are emitted as JSON lines with:
- `timestamp`
- `path`
- `result`
- `copyToClipboard`
- `textLength`

### Path values
- `direct-accessibility` — AX selected-text/value replacement succeeded
- `typed-unicode-events` — unicode typing fallback succeeded
- `special-paste-clipboard` — clipboard + special paste path used
- `special-paste-temporary-clipboard` — temporary clipboard paste path used (clipboard restored)
- `empty-input` — nothing to insert

### Result values
- `pasted`
- `copied-only`
- `not-inserted`
- `empty`

### Smoke/regression runner
Run all core + insertion reliability tests:

```bash
Scripts/run-tests.sh
```

Run insertion decision simulation directly:

```bash
Scripts/run-insertion-reliability.sh --regression

Scripts/run-insertion-reliability.sh \
  --text "hello" --copy true --direct false --typing false --special false \
  --expect-path special-paste-clipboard --expect-result copied-only
```

Use this to validate decision outcomes without requiring live UI automation.

## Built-in Apple model question
Yes — Apple’s `Speech` framework can use on-device recognition where available.
In this scaffold:
- we request standard speech authorizations from system
- we set `requiresOnDeviceRecognition = true` when the API supports it

So it uses Apple’s built-in stack first, and can still fallback to Apple’s
back-end path if the on-device constraints aren’t met on a particular machine/config.

## Notes for future (iOS / Windows)
- macOS scaffold is complete starter here.
- iOS version should use similar `Speech` + local shortcut UX (different permissions/UX).
- Windows version will need a separate implementation path (not covered here).
