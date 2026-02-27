# Local AI Implementation Notes

## Scope

Phase 1 implements managed Ollama-compatible local runtime setup with in-app wizard flow.

## Added components

- `Sources/KeyScribe/Services/LocalAIModelCatalog.swift`
  - beginner-friendly model catalog and recommended model.
- `Sources/KeyScribe/Services/LocalAIRuntimeManager.swift`
  - runtime detection, managed install, runtime start/stop, health check, model pull, model verification.
- `Sources/KeyScribe/Services/LocalAISetupService.swift`
  - setup state machine and UX-facing progress/status.

## Settings additions

`SettingsStore` now persists:

- `KeyScribe.localAISetupCompleted`
- `KeyScribe.localAISelectedModelID`
- `KeyScribe.localAIManagedRuntimeEnabled`
- `KeyScribe.localAIRuntimeVersion`
- `KeyScribe.localAILastHealthCheckEpoch`
- `KeyScribe.promptRewriteRequestTimeoutSeconds`

and includes `applyLocalAIDefaults(selectedModelID:)` for automatic provider configuration.

## UI integration

- `AIMemoryStudioView`
  - new `Local AI Setup` wizard card in Prompt Models page,
  - step visualization (`Select Model`, `Install Runtime`, `Download Model`, `Verify`, `Done`),
  - install/retry/repair/cancel controls,
  - delete-selected-model action with confirmation,
  - rewrite timeout slider in Prompt Models,
  - local runtime-aware provider status text.
- `App` settings provider card
  - local AI readiness row and selected model display.

## Provider messaging updates

- Prompt rewrite failures now map Ollama-local transport/base-url errors to setup guidance.
- Model catalog fetch for Ollama returns explicit local setup/repair guidance on runtime connectivity failures.
- Memory lesson synthesis logs clear local-runtime guidance when Ollama is unreachable.
- Assistant-style local rewrite outputs are suppressed to prevent chat-answer insertion.
- Non-JSON local rewrite outputs now use guarded fallback parsing (embedded JSON extraction + sanitized plain-text fallback) so local models remain usable even when strict JSON is not returned.
- Trailing command-instruction artifacts (for example, `Run the command: ...`) are now stripped from rewrite suggestions unless the user explicitly dictated command instructions.
- Conversation-history assistant turns apply the same command-suffix sanitization so stale artifacts do not keep re-influencing future rewrites.
- Conversation tuple keys now canonicalize coding-app project contexts into a shared coding-workspace bucket, so the same project history is reused across VS Code, Cursor, Antigravity, and similar IDEs.
- Startup behavior now auto-checks and auto-starts local runtime when provider mode is already `Ollama (Local)`.
- First local rewrite request also performs runtime auto-start if needed before failing.

## Future roadmap

Phase 2 should introduce a built-in runtime provider while keeping current Ollama compatibility path.
