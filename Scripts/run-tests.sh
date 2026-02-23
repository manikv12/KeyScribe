#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d "Vendor/Whisper/whisper.xcframework" ]; then
  echo "whisper.xcframework not found, downloading framework..."
  Scripts/update-whisper-framework.sh
fi

swiftc \
  Sources/KeyScribe/Services/ShortcutValidationRules.swift \
  Sources/KeyScribe/Services/DictationInputModeStateMachine.swift \
  Sources/KeyScribe/Services/TextCleanup.swift \
  Sources/KeyScribe/Services/RecognitionTuning.swift \
  Sources/KeyScribe/Services/InsertionDecisionModel.swift \
  Sources/KeyScribe/Services/InsertionDiagnostics.swift \
  Sources/KeyScribe/Services/TextInserter.swift \
  Sources/KeyScribe/Services/InsertionRetryPolicy.swift \
  Scripts/CoreLogicSmokeTests.swift \
  -o /tmp/keyscribe-core-smoke-tests

/tmp/keyscribe-core-smoke-tests
Scripts/run-insertion-reliability.sh --regression

swiftc \
  Sources/KeyScribe/Services/WhisperModelCatalog.swift \
  Scripts/WhisperCatalogSmokeTests.swift \
  -o /tmp/keyscribe-whisper-catalog-smoke-tests

/tmp/keyscribe-whisper-catalog-smoke-tests

swiftc \
  Sources/KeyScribe/Services/ShortcutValidationRules.swift \
  Sources/KeyScribe/Support/ShortcutValidation.swift \
  Sources/KeyScribe/Services/MicrophoneManager.swift \
  Sources/KeyScribe/Services/TextCleanup.swift \
  Sources/KeyScribe/Services/SettingsStore.swift \
  Scripts/SettingsStoreWhisperSmokeTests.swift \
  -o /tmp/keyscribe-settings-whisper-smoke-tests

/tmp/keyscribe-settings-whisper-smoke-tests
