# KeyScribe Native Runtime Sidecar

Minimal Rust stdio sidecar runtime using newline-delimited JSON (NDJSON).

## Prerequisites

- Rust toolchain ([rustup](https://rustup.rs/))

## Build

```bash
cd electron/native
cargo build -p keyscribe-runtime
```

## Run

```bash
cd electron/native
cargo run -p keyscribe-runtime
```

The runtime reads one JSON request per line from `stdin` and writes one JSON response per line to `stdout`.

## Quick Smoke Test

```bash
cd electron/native
printf '%s\n' \
  '{"id":1,"method":"runtime.ping","params":{"hello":"world"}}' \
  '{"id":2,"method":"runtime.get_capabilities"}' \
  '{"id":3,"method":"runtime.health"}' \
  | cargo run -q -p keyscribe-runtime
```

Example response lines:

```json
{"id":1,"result":{"echo":{"hello":"world"},"ok":true,"timestampMs":1700000000000}}
{"id":2,"result":{"appleSpeechAvailable":true,"whisperAvailable":false,"caretBoundsAvailable":true}}
{"id":3,"result":{"status":"ok","uptimeMs":1,"version":"0.1.0"}}
```

## Protocol Methods

- `runtime.ping`
  - Returns a liveness response with `ok`, `timestampMs`, and `echo` (the request `params` payload).
- `runtime.get_capabilities`
  - Returns runtime capability flags.
- `runtime.health`
  - Returns process health information including `status`, `uptimeMs`, and `version`.
- `runtime.start_dictation`
  - Updates runtime session state to dictating and returns `ok`, `status`, `isDictating`, and `reason`.
- `runtime.stop_dictation`
  - Updates runtime session state to idle and returns `ok`, `status`, `isDictating`, and `reason`.
- `runtime.insert_text`
  - Accepts `params.text` (or `params.transcript`) and returns `ok`, `status`, `reason`, and `insertedChars`.
- `runtime.get_status`
  - Returns runtime session state including `status`, `isDictating`, and `lastInsertedTextLength`.

## NDJSON Examples for New Methods

```bash
cd electron/native
printf '%s\n' \
  '{"id":10,"method":"runtime.start_dictation","params":{}}' \
  '{"id":11,"method":"runtime.insert_text","params":{"text":"hello world"}}' \
  '{"id":12,"method":"runtime.get_status","params":{}}' \
  '{"id":13,"method":"runtime.stop_dictation","params":{}}' \
  | cargo run -q -p keyscribe-runtime
```

Example response lines:

```json
{"id":10,"result":{"ok":true,"status":"dictating","isDictating":true,"reason":"Dictation started in native runtime state machine."}}
{"id":11,"result":{"ok":true,"status":"inserted","reason":"Text accepted by native runtime.","insertedChars":11}}
{"id":12,"result":{"ok":true,"status":"dictating","isDictating":true,"lastInsertedTextLength":11}}
{"id":13,"result":{"ok":true,"status":"idle","isDictating":false,"reason":"Dictation stopped in native runtime state machine."}}
```
