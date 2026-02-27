# Local AI Setup Guide (No Technical Steps)

This guide is for non-technical users.

## What this setup does

KeyScribe can run prompt correction and memory extraction with a local model on your Mac.
You do not need to connect OpenAI, Anthropic, or any other cloud provider for this flow.

## Setup steps

1. Open KeyScribe Settings.
2. Go to **AI Models**.
3. Click **Open AI Studio…**.
4. Open the **Prompt Models** page.
5. In **Local AI Setup (No Account Needed)**:
   - choose a model from the list,
   - click **Install Selected Model**.
6. Wait until the setup step list shows **Done**.

## What happens automatically

After setup, KeyScribe automatically:

- sets provider to **Ollama (Local)**,
- sets base URL to `http://localhost:11434/v1`,
- selects the model you chose,
- enables AI prompt correction,
- enables AI memory assistant when memory feature flag is enabled.

## If setup fails

1. Stay in **Prompt Models**.
2. Click **Retry** or **Repair Local AI**.
3. Click **Refresh Status**.
4. Continue only when status shows **Ready**.

## If the suggestion answers your request instead of rewriting it

KeyScribe suppresses assistant-style local model replies and leaked internal conversation/template payload text.
If a local model fails to return strict JSON, KeyScribe now attempts a safe fallback parse and only inserts text that passes rewrite-safety checks.
If you still see odd behavior:

1. Click **Repair Local AI**.
2. Increase **Rewrite request timeout**.
3. Try another recommended local model in the setup list.

If you previously saw trailing text such as `Run the command: ...` appended to rewrites:

1. Update to the latest build.
2. Retry once in the same chat surface.
3. The suffix is now stripped before insertion and also sanitized out of conversation-history turns.

## Codex app note

AI prompt correction is not disabled for Codex app.
If rewrites seem to pass through unchanged, it is usually because the local model returned an invalid/non-rewrite response and KeyScribe protected insertion.
With the latest update, non-JSON local replies are handled with a guarded fallback parser to improve rewrite reliability in Codex and similar apps.

## Cross-IDE project history

If you work on the same project in multiple coding apps (for example VS Code, Cursor, and Antigravity), KeyScribe now reuses the same conversation-history bucket by project instead of splitting by app.

## Timeout control (all providers/models)

If rewrites time out, in **Prompt Models** adjust **Rewrite request timeout**.

- Increase the slider for slower local Macs.
- This timeout applies across rewrite and memory-assistant model requests.

## Delete a downloaded local model

In **Local AI Setup**:

1. Select the model from the model picker.
2. Click **Delete Selected Model**.
3. Confirm delete.

You can reinstall later with **Install Selected Model**.

## Notes

- Initial install requires internet access to download runtime and model.
- After download, inference runs locally on-device.
- You can switch provider mode later from the same page if needed.
- If Local mode is already configured, KeyScribe now auto-checks and auto-starts local runtime on app startup.
