#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc \
  Sources/KeyScribe/Services/InsertionDecisionModel.swift \
  Sources/KeyScribe/Services/InsertionDiagnostics.swift \
  Sources/KeyScribe/Services/TextInserter.swift \
  Scripts/InsertionReliabilityRunner.swift \
  -o /tmp/keyscribe-insertion-reliability

if [[ $# -eq 0 ]]; then
  /tmp/keyscribe-insertion-reliability --regression
else
  /tmp/keyscribe-insertion-reliability "$@"
fi
