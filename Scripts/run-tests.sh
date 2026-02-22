#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc \
  Sources/KeyScribe/Services/ShortcutValidationRules.swift \
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
