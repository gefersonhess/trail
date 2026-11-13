use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::{peek, pull_request, review, sidebyside, worktree};

const PARSE_ERROR: i64 = -32700;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;
const GIT_ERROR: i64 = 1;

#[derive(Deserialize)]
struct Request {
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Deserialize)]
struct OpenParams {
    repo: PathBuf,
    base: String,
    head: String,
}

#[derive(Deserialize)]
struct FileDiffParams {
    repo: PathBuf,
    base_commit: String,
    head_commit: String,
    old_path: Option<String>,
    new_path: Option<String>,
}

#[derive(Deserialize)]
struct PeekParams {
    repo: PathBuf,
    commit: String,
    language: String,
    name: String,
    qualifier: Option<String>,
    from_path: String,
}

#[derive(Deserialize)]
struct CheckoutParams {
    repo: PathBuf,
    commit: String,
}

#[derive(Deserialize)]
struct PullRequestParams {
    repo: PathBuf,
    number: u32,
}

struct RpcError {
    code: i64,
    message: String,
}

pub fn serve(input: impl BufRead, mut output: impl Write) -> io::Result<()> {
    log("serving");
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let started = Instant::now();
        let (id, method, result) = match serde_json::from_str::<Request>(&line) {
            Ok(req) => {
                let result = dispatch(&req.method, req.params);
                (req.id, req.method, result)
            }
            Err(e) => (
                Some(Value::Null),
                String::from("<unparsed>"),
                Err(RpcError {
                    code: PARSE_ERROR,
                    message: e.to_string(),
                }),
            ),
        };
        let elapsed = started.elapsed().as_millis();
        match &result {
            Ok(_) => log(&format!("{method} ok in {elapsed}ms")),
            Err(e) => log(&format!("{method} failed in {elapsed}ms: {}", e.message)),
        }
        let Some(id) = id else { continue };
        let response = match result {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(e) => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": e.code, "message": e.message },
            }),
        };
        writeln!(output, "{response}")?;
        output.flush()?;
    }
    log("stdin closed, exiting");
    Ok(())
}

fn dispatch(method: &str, params: Value) -> Result<Value, RpcError> {
    match method {
        "open" => {
            let p: OpenParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let review = review::open(&p.repo, &p.base, &p.head).map_err(|message| RpcError {
                code: GIT_ERROR,
                message,
            })?;
            log(&format!(
                "open: {} files, {} hunks, {} nodes, {} edges",
                review.files.len(),
                review.hunks.len(),
                review.nodes.len(),
                review.edges.len()
            ));
            Ok(serde_json::to_value(review).expect("review serializes"))
        }
        "file_diff" => {
            let p: FileDiffParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let diff = sidebyside::compute(
                &p.repo,
                &p.base_commit,
                &p.head_commit,
                p.old_path.as_deref(),
                p.new_path.as_deref(),
            )
            .map_err(|message| RpcError {
                code: GIT_ERROR,
                message,
            })?;
            Ok(serde_json::to_value(diff).expect("side by side serializes"))
        }
        "peek" => {
            let p: PeekParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let peek = peek::find(
                &p.repo,
                &p.commit,
                &p.language,
                &p.name,
                p.qualifier.as_deref(),
                &p.from_path,
            )
            .map_err(|message| RpcError {
                code: GIT_ERROR,
                message,
            })?;
            Ok(serde_json::to_value(peek).expect("peek serializes"))
        }
        "checkout" => {
            let p: CheckoutParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let checkout = worktree::checkout(&p.repo, &p.commit).map_err(|message| RpcError {
                code: GIT_ERROR,
                message,
            })?;
            Ok(serde_json::to_value(checkout).expect("checkout serializes"))
        }
        "pull_request" => {
            let p: PullRequestParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let pr = pull_request::fetch(&p.repo, p.number).map_err(|message| RpcError {
                code: GIT_ERROR,
                message,
            })?;
            Ok(serde_json::to_value(pr).expect("pull request serializes"))
        }
        _ => Err(RpcError {
            code: METHOD_NOT_FOUND,
            message: format!("unknown method {method}"),
        }),
    }
}

pub fn log(message: &str) {
    let ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    eprintln!("[{ms}] {message}");
}
