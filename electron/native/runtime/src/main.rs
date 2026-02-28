use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{self, BufRead, Write};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

#[derive(Debug, Deserialize)]
struct Request {
    #[serde(default)]
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Serialize)]
struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<ErrorResponse>,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    code: String,
    message: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeCapabilities {
    apple_speech_available: bool,
    whisper_available: bool,
    caret_bounds_available: bool,
}

#[derive(Debug, Default)]
struct RuntimeState {
    is_dictating: bool,
    last_inserted_text: Option<String>,
}

fn main() {
    let stdin = io::stdin();
    let mut stdout = io::stdout();
    let started = Instant::now();
    let mut runtime_state = RuntimeState::default();

    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(err) => {
                let response = Response {
                    id: None,
                    result: None,
                    error: Some(ErrorResponse {
                        code: "READ_ERROR".to_string(),
                        message: format!("Failed to read stdin: {err}"),
                    }),
                };
                if write_response(&mut stdout, &response).is_err() {
                    break;
                }
                continue;
            }
        };

        if line.trim().is_empty() {
            continue;
        }

        let request: Request = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(err) => {
                let response = Response {
                    id: None,
                    result: None,
                    error: Some(ErrorResponse {
                        code: "INVALID_JSON".to_string(),
                        message: format!("Invalid JSON request: {err}"),
                    }),
                };
                if write_response(&mut stdout, &response).is_err() {
                    break;
                }
                continue;
            }
        };

        let response = handle_request(request, &started, &mut runtime_state);
        if write_response(&mut stdout, &response).is_err() {
            break;
        }
    }
}

fn handle_request(request: Request, started: &Instant, runtime_state: &mut RuntimeState) -> Response {
    match request.method.as_str() {
        "runtime.ping" => Response {
            id: request.id,
            result: Some(json!({
                "ok": true,
                "timestampMs": now_unix_ms(),
                "echo": request.params,
            })),
            error: None,
        },
        "runtime.get_capabilities" => {
            let capabilities = RuntimeCapabilities {
                apple_speech_available: cfg!(target_os = "macos"),
                whisper_available: false,
                caret_bounds_available: cfg!(target_os = "macos"),
            };
            Response {
                id: request.id,
                result: Some(json!(capabilities)),
                error: None,
            }
        }
        "runtime.health" => Response {
            id: request.id,
            result: Some(json!({
                "status": "ok",
                "uptimeMs": started.elapsed().as_millis(),
                "version": env!("CARGO_PKG_VERSION"),
            })),
            error: None,
        },
        "runtime.start_dictation" => Response {
            id: request.id,
            result: Some(start_dictation(runtime_state)),
            error: None,
        },
        "runtime.stop_dictation" => Response {
            id: request.id,
            result: Some(stop_dictation(runtime_state)),
            error: None,
        },
        "runtime.insert_text" => Response {
            id: request.id,
            result: Some(insert_text(runtime_state, request.params)),
            error: None,
        },
        "runtime.get_status" => Response {
            id: request.id,
            result: Some(get_status(runtime_state)),
            error: None,
        },
        _ => Response {
            id: request.id,
            result: None,
            error: Some(ErrorResponse {
                code: "METHOD_NOT_FOUND".to_string(),
                message: format!("Unsupported method: {}", request.method),
            }),
        },
    }
}

fn write_response(stdout: &mut io::Stdout, response: &Response) -> io::Result<()> {
    serde_json::to_writer(&mut *stdout, response)?;
    stdout.write_all(b"\n")?;
    stdout.flush()
}

fn now_unix_ms() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis())
}

fn start_dictation(runtime_state: &mut RuntimeState) -> Value {
    runtime_state.is_dictating = true;
    json!({
        "ok": true,
        "status": "dictating",
        "isDictating": true,
        "reason": "Dictation started in native runtime state machine."
    })
}

fn stop_dictation(runtime_state: &mut RuntimeState) -> Value {
    runtime_state.is_dictating = false;
    json!({
        "ok": true,
        "status": "idle",
        "isDictating": false,
        "reason": "Dictation stopped in native runtime state machine."
    })
}

fn insert_text(runtime_state: &mut RuntimeState, params: Value) -> Value {
    let text = extract_insert_text(&params);
    if let Some(valid_text) = text {
        runtime_state.last_inserted_text = Some(valid_text.clone());
        return json!({
            "ok": true,
            "status": "inserted",
            "reason": "Text accepted by native runtime.",
            "insertedChars": valid_text.chars().count()
        });
    }

    json!({
        "ok": false,
        "status": "noop",
        "reason": "No text was provided for runtime.insert_text."
    })
}

fn get_status(runtime_state: &RuntimeState) -> Value {
    json!({
        "ok": true,
        "status": if runtime_state.is_dictating { "dictating" } else { "idle" },
        "isDictating": runtime_state.is_dictating,
        "lastInsertedTextLength": runtime_state.last_inserted_text.as_ref().map(|text| text.chars().count()),
    })
}

fn extract_insert_text(params: &Value) -> Option<String> {
    match params {
        Value::String(text) => normalized_non_empty_string(text),
        Value::Object(map) => {
            if let Some(Value::String(text)) = map.get("text") {
                return normalized_non_empty_string(text);
            }

            if let Some(Value::String(text)) = map.get("transcript") {
                return normalized_non_empty_string(text);
            }

            None
        }
        _ => None,
    }
}

fn normalized_non_empty_string(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}
