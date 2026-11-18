use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use serde_json::{Value, json};

use crate::{diff, impact, peek, pull_request, review, sidebyside, worktree};

const PARSE_ERROR: i64 = -32700;
const INTERNAL_ERROR: i64 = -32603;
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
    /// Ask the language server: off by default for `open`, whose name-matched
    /// calls are enough for the plugin, on by default for `impact`.
    lsp: Option<bool>,
    #[serde(default)]
    ignore: Vec<String>,
    #[serde(default = "enabled")]
    ignore_defaults: bool,
}

fn enabled() -> bool {
    true
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

#[derive(Deserialize)]
struct ReviewThreadsParams {
    repo: PathBuf,
    url: String,
    number: u32,
}

#[derive(Deserialize)]
struct UpdateThreadParams {
    repo: PathBuf,
    url: String,
    number: u32,
    thread: String,
    #[serde(default)]
    body: String,
    state: Option<String>,
}

#[derive(Deserialize)]
struct SubmitReviewParams {
    repo: PathBuf,
    url: String,
    number: u32,
    commit: String,
    event: Option<String>,
    #[serde(default)]
    body: String,
    #[serde(default)]
    comments: Vec<pull_request::ReviewComment>,
}

struct RpcError {
    code: i64,
    message: String,
}

pub fn serve(input: impl BufRead, output: impl Write + Send + 'static) -> io::Result<()> {
    log("serving");
    let output = Arc::new(Mutex::new(output));
    let mut background = Vec::new();
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let request = serde_json::from_str::<Request>(&line);
        // Asking the language server can take long while it indexes; run it
        // on its own thread so diffs and peeks stay responsive.
        let slow = request
            .as_ref()
            .is_ok_and(|r| (r.method == "open" && r.params["lsp"] == true) || r.method == "impact");
        let output = Arc::clone(&output);
        let work = move || handle(request, &output);
        if slow {
            background.push(std::thread::spawn(work));
        } else {
            work()?;
        }
    }
    for handle in background {
        handle
            .join()
            .map_err(|_| io::Error::other("request thread panicked"))??;
    }
    log("stdin closed, exiting");
    Ok(())
}

fn handle(
    request: Result<Request, serde_json::Error>,
    output: &Mutex<impl Write>,
) -> io::Result<()> {
    let started = Instant::now();
    let (id, method, result) = match request {
        Ok(req) => {
            // A bug in one request must still answer it, or the client waits forever.
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                dispatch(&req.method, req.params)
            }))
            .unwrap_or_else(|panic| {
                let message = panic
                    .downcast_ref::<String>()
                    .map(String::as_str)
                    .or_else(|| panic.downcast_ref::<&str>().copied())
                    .unwrap_or("unknown panic");
                Err(RpcError {
                    code: INTERNAL_ERROR,
                    message: format!("the engine crashed: {message}"),
                })
            });
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
    let Some(id) = id else { return Ok(()) };
    let response = match result {
        Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
        Err(e) => json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": e.code, "message": e.message },
        }),
    };
    let mut output = output
        .lock()
        .map_err(|_| io::Error::other("output lock poisoned"))?;
    writeln!(output, "{response}")?;
    output.flush()
}

fn dispatch(method: &str, params: Value) -> Result<Value, RpcError> {
    match method {
        "open" => {
            let p: OpenParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let ignore = diff::Ignore::new(&p.ignore, p.ignore_defaults);
            let review = review::open(&p.repo, &p.base, &p.head, p.lsp.unwrap_or(false), &ignore)
                .map_err(|message| RpcError {
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
        "impact" => {
            let p: OpenParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let ignore = diff::Ignore::new(&p.ignore, p.ignore_defaults);
            let impact = impact::compute(&p.repo, &p.base, &p.head, p.lsp.unwrap_or(true), &ignore)
                .map_err(|message| RpcError {
                    code: GIT_ERROR,
                    message,
                })?;
            log(&format!("impact: {} paths", impact.paths.len()));
            Ok(serde_json::to_value(impact).expect("impact serializes"))
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
        "update_thread" => {
            let p: UpdateThreadParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            pull_request::update_thread(
                &p.repo,
                &p.url,
                p.number,
                &p.thread,
                &p.body,
                p.state.as_deref(),
            )
            .map_err(|message| RpcError {
                code: GIT_ERROR,
                message,
            })?;
            Ok(serde_json::json!({}))
        }
        "review_threads" => {
            let p: ReviewThreadsParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let threads =
                pull_request::review_threads(&p.repo, &p.url, p.number).map_err(|message| {
                    RpcError {
                        code: GIT_ERROR,
                        message,
                    }
                })?;
            Ok(serde_json::to_value(threads).expect("threads serialize"))
        }
        "submit_review" => {
            let p: SubmitReviewParams = serde_json::from_value(params).map_err(|e| RpcError {
                code: INVALID_PARAMS,
                message: e.to_string(),
            })?;
            let submitted = pull_request::submit_review(
                &p.repo,
                &p.url,
                p.number,
                &p.commit,
                p.event.as_deref(),
                &p.body,
                &p.comments,
            )
            .map_err(|message| RpcError {
                code: GIT_ERROR,
                message,
            })?;
            Ok(serde_json::to_value(submitted).expect("submitted review serializes"))
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
