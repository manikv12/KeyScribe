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
  Sources/KeyScribe/Support/FeatureFlags.swift \
  Sources/KeyScribe/Services/MicrophoneManager.swift \
  Sources/KeyScribe/Services/TextCleanup.swift \
  Sources/KeyScribe/Services/AdaptiveCorrectionStore.swift \
  Sources/KeyScribe/Services/CrashReporter.swift \
  Sources/KeyScribe/Services/SettingsStore.swift \
  Sources/KeyScribe/Services/PromptRewriteProviderOAuthService.swift \
  Scripts/SettingsStoreWhisperSmokeTests.swift \
  -o /tmp/keyscribe-settings-whisper-smoke-tests

/tmp/keyscribe-settings-whisper-smoke-tests

swiftc \
  Sources/KeyScribe/Services/ShortcutValidationRules.swift \
  Sources/KeyScribe/Support/ShortcutValidation.swift \
  Sources/KeyScribe/Support/FeatureFlags.swift \
  Sources/KeyScribe/Services/MicrophoneManager.swift \
  Sources/KeyScribe/Services/TextCleanup.swift \
  Sources/KeyScribe/Services/AdaptiveCorrectionStore.swift \
  Sources/KeyScribe/Services/CrashReporter.swift \
  Sources/KeyScribe/Services/SettingsStore.swift \
  Sources/KeyScribe/Services/PromptRewriteProviderOAuthService.swift \
  Sources/KeyScribe/Services/Memory/MemoryModels.swift \
  Sources/KeyScribe/Services/Memory/MemorySQLiteStore.swift \
  Sources/KeyScribe/Services/Memory/MemoryRewriteRetrievalService.swift \
  Sources/KeyScribe/Services/Memory/MemoryRewriteExtractionProvider.swift \
  Sources/KeyScribe/Services/Memory/ConversationMemoryPromotionService.swift \
  Sources/KeyScribe/Services/ConversationTagInferenceService.swift \
  Sources/KeyScribe/Services/LocalAIRuntimeManager.swift \
  Sources/KeyScribe/Services/PromptRewriteConversationStore.swift \
  Sources/KeyScribe/Services/PromptRewriteModelCatalogService.swift \
  Sources/KeyScribe/Services/PromptRewriteService.swift \
  Scripts/PromptRewriteSmokeTests.swift \
  -o /tmp/keyscribe-prompt-rewrite-smoke-tests

/tmp/keyscribe-prompt-rewrite-smoke-tests

swiftc \
  Sources/KeyScribe/Services/ShortcutValidationRules.swift \
  Sources/KeyScribe/Support/ShortcutValidation.swift \
  Sources/KeyScribe/Support/FeatureFlags.swift \
  Sources/KeyScribe/Services/MicrophoneManager.swift \
  Sources/KeyScribe/Services/TextCleanup.swift \
  Sources/KeyScribe/Services/AdaptiveCorrectionStore.swift \
  Sources/KeyScribe/Services/CrashReporter.swift \
  Sources/KeyScribe/Services/SettingsStore.swift \
  Sources/KeyScribe/Services/PromptRewriteProviderOAuthService.swift \
  Sources/KeyScribe/Services/PromptRewriteModelCatalogService.swift \
  Scripts/PromptRewriteModelCatalogSmokeTests.swift \
  -o /tmp/keyscribe-prompt-rewrite-model-catalog-smoke-tests

/tmp/keyscribe-prompt-rewrite-model-catalog-smoke-tests

swiftc \
  Sources/KeyScribe/Services/Memory/MemoryModels.swift \
  Sources/KeyScribe/Services/Memory/MemoryProviderDiscoveryService.swift \
  Sources/KeyScribe/Services/Memory/MemorySourceAdapters.swift \
  Sources/KeyScribe/Services/ShortcutValidationRules.swift \
  Sources/KeyScribe/Support/ShortcutValidation.swift \
  Sources/KeyScribe/Support/FeatureFlags.swift \
  Sources/KeyScribe/Services/MicrophoneManager.swift \
  Sources/KeyScribe/Services/TextCleanup.swift \
  Sources/KeyScribe/Services/AdaptiveCorrectionStore.swift \
  Sources/KeyScribe/Services/CrashReporter.swift \
  Sources/KeyScribe/Services/ConversationTagInferenceService.swift \
  Sources/KeyScribe/Services/SettingsStore.swift \
  Sources/KeyScribe/Services/PromptRewriteProviderOAuthService.swift \
  Sources/KeyScribe/Services/PromptRewriteConversationStore.swift \
  Sources/KeyScribe/Services/Memory/ConversationMemoryPromotionService.swift \
  Sources/KeyScribe/Services/Memory/MemoryRewriteExtractionProvider.swift \
  Sources/KeyScribe/Services/Memory/MemorySQLiteStore.swift \
  Sources/KeyScribe/Services/Memory/MemoryIndexingService.swift \
  Scripts/MemoryIndexingSmokeTests.swift \
  -o /tmp/keyscribe-memory-indexing-smoke-tests

/tmp/keyscribe-memory-indexing-smoke-tests
