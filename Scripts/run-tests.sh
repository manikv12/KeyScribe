#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc \
  Sources/KeyScribe/Services/ShortcutValidation.swift \
  Sources/KeyScribe/Services/TextCleanup.swift \
  Sources/KeyScribe/Services/RecognitionTuning.swift \
  Sources/KeyScribe/Services/TextInserter.swift \
  Sources/KeyScribe/Services/InsertionRetryPolicy.swift \
  Scripts/CoreLogicSmokeTests.swift \
  -o /tmp/keyscribe-smoke-tests

/tmp/keyscribe-smoke-tests
