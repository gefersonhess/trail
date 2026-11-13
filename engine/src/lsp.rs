use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::rpc::log;

/// A language server process speaking LSP over stdio.
pub struct Client {
    child: Child,
    stdin: ChildStdin,
    messages: Receiver<Value>,
    next_id: i64,
    name: String,
}

/// Running servers by language and root, with the commit each root holds.
type Clients = HashMap<(String, PathBuf), (String, Client)>;

static CLIENTS: LazyLock<Mutex<Clients>> = LazyLock::new(Default::default);

/// The command for a language's server, overridable for tests and unusual installs.
fn command(language: &str) -> Option<String> {
    let (var, default) = match language {
        "go" => ("TRAIL_GOPLS", "gopls"),
        "rust" => ("TRAIL_RUST_ANALYZER", "rust-analyzer"),
        _ => return None,
    };
    Some(std::env::var(var).unwrap_or_else(|_| default.to_string()))
}

/// Runs `f` with a running server for `language` at `root`, which holds
/// `commit`. One server is kept per language and root; it is restarted when the
/// root has moved to another commit, so its index matches the files.
pub fn with_client<T>(
    language: &str,
    root: &Path,
    commit: &str,
    f: impl FnOnce(&mut Client) -> Result<T, String>,
) -> Result<T, String> {
    let mut clients = CLIENTS
        .lock()
        .map_err(|_| "language server lock poisoned")?;
    let map_key = (language.to_string(), root.to_path_buf());
    let stale = clients.get(&map_key).is_some_and(|(at, _)| at != commit);
    if stale && let Some((_, client)) = clients.remove(&map_key) {
        client.shutdown();
    }
    if !clients.contains_key(&map_key) {
        let cmd = command(language).ok_or_else(|| format!("no language server for {language}"))?;
        let client = Client::start(&cmd, root)?;
        clients.insert(map_key.clone(), (commit.to_string(), client));
    }
    let (_, client) = clients.get_mut(&map_key).expect("inserted above");
    let result = f(client);
    if result.is_err()
        && let Some((_, client)) = clients.remove(&map_key)
    {
        client.shutdown();
    }
    result
}

pub fn uri(path: &Path) -> String {
    format!("file://{}", path.display())
}

pub fn path_of(uri: &str) -> Option<PathBuf> {
    uri.strip_prefix("file://").map(PathBuf::from)
}

impl Client {
    fn start(cmd: &str, root: &Path) -> Result<Client, String> {
        log(&format!("starting {cmd} in {}", root.display()));
        let mut child = Command::new(cmd)
            .current_dir(root)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("starting {cmd}: {e}"))?;
        let stdin = child.stdin.take().expect("piped");
        let stdout = child.stdout.take().expect("piped");
        let (tx, messages) = mpsc::channel();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            while let Some(message) = read_message(&mut reader) {
                if tx.send(message).is_err() {
                    break;
                }
            }
        });
        let mut client = Client {
            child,
            stdin,
            messages,
            next_id: 1,
            name: cmd.to_string(),
        };
        let root_uri = uri(root);
        client.request(
            "initialize",
            json!({
                "processId": std::process::id(),
                "rootUri": root_uri,
                "workspaceFolders": [{ "uri": root_uri, "name": "review" }],
                "capabilities": {
                    "textDocument": { "callHierarchy": { "dynamicRegistration": false } },
                    "window": { "workDoneProgress": true },
                    "workspace": { "configuration": true, "workspaceFolders": true },
                },
            }),
            Duration::from_secs(60),
        )?;
        client.notify("initialized", json!({}))?;
        Ok(client)
    }

    fn send(&mut self, message: Value) -> Result<(), String> {
        let body = message.to_string();
        write!(self.stdin, "Content-Length: {}\r\n\r\n{body}", body.len())
            .and_then(|()| self.stdin.flush())
            .map_err(|e| format!("writing to {}: {e}", self.name))
    }

    fn notify(&mut self, method: &str, params: Value) -> Result<(), String> {
        self.send(json!({ "jsonrpc": "2.0", "method": method, "params": params }))
    }

    /// Sends a request and waits for its response, answering the server's own
    /// requests (configuration, progress) on the way so it does not stall.
    pub fn request(
        &mut self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(json!({ "jsonrpc": "2.0", "id": id, "method": method, "params": params }))?;
        let deadline = Instant::now() + timeout;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let message = match self.messages.recv_timeout(left) {
                Ok(m) => m,
                Err(RecvTimeoutError::Timeout) => {
                    return Err(format!("{} did not answer {method} in time", self.name));
                }
                Err(RecvTimeoutError::Disconnected) => return Err(format!("{} exited", self.name)),
            };
            if message.get("method").is_some() {
                if let Some(server_id) = message.get("id") {
                    let result = match message["method"].as_str() {
                        Some("workspace/configuration") => {
                            let n = message["params"]["items"].as_array().map_or(0, Vec::len);
                            Value::Array(vec![Value::Null; n])
                        }
                        _ => Value::Null,
                    };
                    self.send(json!({ "jsonrpc": "2.0", "id": server_id, "result": result }))?;
                }
                continue;
            }
            if message.get("id") == Some(&json!(id)) {
                if let Some(error) = message.get("error") {
                    return Err(format!("{} {method}: {}", self.name, error["message"]));
                }
                return Ok(message.get("result").cloned().unwrap_or(Value::Null));
            }
        }
    }

    fn shutdown(mut self) {
        let _ = self.request("shutdown", Value::Null, Duration::from_secs(5));
        let _ = self.notify("exit", Value::Null);
        let _ = self.child.wait();
    }
}

fn read_message(reader: &mut impl BufRead) -> Option<Value> {
    let mut length = None;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).ok()? == 0 {
            return None;
        }
        let line = line.trim_end();
        if line.is_empty() {
            break;
        }
        if let Some(n) = line.strip_prefix("Content-Length:") {
            length = n.trim().parse().ok();
        }
    }
    let mut body = vec![0; length?];
    reader.read_exact(&mut body).ok()?;
    serde_json::from_slice(&body).ok()
}
