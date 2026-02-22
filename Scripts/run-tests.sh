#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swiftc Sources/KeyScribe/Services/RecognitionTuning.swift Scripts/RecognitionTuningSmokeTests.swift -o /tmp/keyscribe-smoke-tests
/tmp/keyscribe-smoke-tests
