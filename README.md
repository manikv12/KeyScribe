# KeyScribe

KeyScribe is a macOS menu-bar dictation app that transcribes speech and inserts the result into the currently focused text field.

The app runs as a menu bar utility (`LSUIElement`), so it does not show a Dock icon.

## What the app does

- Captures speech with a selectable transcription engine:
  - Apple Speech (`SFSpeechRecognizer`)
  - whisper.cpp (on-device models)
- Cleans transcript text before insert (spacing, punctuation, capitalization, duplicate-word cleanup).
- Inserts text into the active app with reliability fallbacks.
- Stores the last 20 transcripts in local history.
- Lets you paste the most recent transcript with `⌥⌘V` without needing to copy from history first.

## Transcription engines

- **Apple Speech**:
  - Works out of the box once permissions are granted.
  - Supports local/cloud recognition mode options.
- **whisper.cpp**:
  - Runs on-device using downloaded model files (`tiny.en`, `base.en`, `small.en`).
  - Model downloads are explicit user actions in Settings (no background model downloads).
  - If whisper is selected and no model is installed, dictation is blocked until a model is installed.

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
- Requires **Accessibility** and **Microphone** permissions
- **Speech Recognition** permission is required only when Apple Speech engine is selected
- Tested on macOS 13.3 and later

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

## Memory rewrite preview (AI-filtered indexing)

KeyScribe can learn from local chat-history files and show a rewrite preview before text is inserted.

### How indexing works now

- Indexing scans local provider folders (for example `.codex`, `.claude`, `.cursor`, `.copilot`, `.gemini`, `.windsurf`, `.codeium`).
- Parsed file content is **not persisted** as memory cards/events unless AI-backed rewrite extraction returns valid rewrite signal.
- This prevents non-AI fallback indexing from filling the database with low-signal/junk memories.
- Validation-oriented data from AI-backed extraction is still retained (for example lesson confidence and rewrite metadata).

### Controls

- Go to `Settings -> Memory & Sources` to control this feature.
- Turn on `Enable AI memory assistant` to allow indexing + rewrite suggestions.
- Use provider/folder toggles to pick which sources are allowed.
- Click `Rescan` to detect source folders and optionally start indexing.
- Click `Rebuild Index` when you want to re-index from scratch.
- `Clear Memories` removes indexed memory cards and rewrite entries.
- `Clear Archive` removes all indexed source/archive rows.

When a final transcript is ready:

- KeyScribe asks the rewrite backend for a suggestion using indexed memory context.
- A blocking preview dialog appears with:
  - `Use Suggested`
  - `Edit Then Insert`
  - `Insert Original`
- If the provider fails, a blocking fallback dialog appears with:
  - `Retry`
  - `Insert Original`
  - `Cancel`

This is opt-in. Rewrite/provider behavior is configurable behind the backend service layer.

## Build and install

Build app + drag-and-drop DMG:

```bash
./build.sh
```

`build.sh` will auto-fetch `whisper.xcframework` into `Vendor/Whisper/` if it is missing.

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

The smoke suite includes prompt-rewrite and memory-indexing coverage.

Run insertion decision regression only:

```bash
Scripts/run-insertion-reliability.sh --regression
```

## Project structure

- `Package.swift` - Swift package entry
- `Sources/KeyScribe/App.swift` - app lifecycle, status menu, permission flow, icon state, insertion orchestration
- `Sources/KeyScribe/Services/SpeechTranscriber.swift` - transcription engine router
- `Sources/KeyScribe/Services/AppleSpeechTranscriber.swift` - Apple Speech capture + recognition pipeline
- `Sources/KeyScribe/Services/WhisperTranscriber.swift` - whisper.cpp capture + transcription pipeline
- `Sources/KeyScribe/Services/WhisperModelCatalog.swift` - curated whisper model metadata
- `Sources/KeyScribe/Services/WhisperModelManager.swift` - model download/install/delete lifecycle
- `Sources/KeyScribe/Services/TextInserter.swift` - insertion engine and paste/typing fallbacks
- `Sources/KeyScribe/Services/HotkeyManager.swift` - hold-to-talk and one-shot hotkeys
- `Sources/KeyScribe/Services/TranscriptHistoryStore.swift` - local transcript history persistence
- `Resources/Info.plist` - app metadata and permission keys
- `Scripts/update-whisper-framework.sh` - helper script to fetch/update local whisper XCFramework
