use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU32, Ordering};

use serde_json::{Value, json};

struct Repo(PathBuf);

impl Repo {
    fn new() -> Self {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let dir = std::env::temp_dir().join(format!(
            "trail-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let repo = Repo(dir);
        repo.git(&["init", "-q", "-b", "main"]);
        repo.git(&["config", "user.email", "t@example.com"]);
        repo.git(&["config", "user.name", "t"]);
        repo
    }

    fn git(&self, args: &[&str]) {
        let status = Command::new("git")
            .arg("-C")
            .arg(&self.0)
            .args(args)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    }

    fn write(&self, path: &str, content: &str) {
        let full = self.0.join(path);
        std::fs::create_dir_all(full.parent().unwrap()).unwrap();
        std::fs::write(full, content).unwrap();
    }

    fn commit(&self, message: &str) {
        self.git(&["add", "-A"]);
        self.git(&["commit", "-q", "-m", message]);
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Repo {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn serve(requests: &[Value]) -> Vec<Value> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_trail"))
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut stdin = child.stdin.take().unwrap();
        for r in requests {
            writeln!(stdin, "{r}").unwrap();
        }
    }
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "stderr: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

fn open(repo: &Repo, base: &str, head: &str) -> Value {
    let responses = serve(&[json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "open",
        "params": { "repo": repo.path(), "base": base, "head": head },
    })]);
    assert_eq!(responses.len(), 1);
    responses.into_iter().next().unwrap()
}

fn file<'a>(result: &'a Value, path: &str) -> &'a Value {
    result["files"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["path"] == path)
        .unwrap_or_else(|| panic!("{path} not in {result}"))
}

fn hunks_of<'a>(result: &'a Value, path: &str) -> Vec<&'a Value> {
    result["hunks"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|h| h["file"] == path)
        .collect()
}

#[test]
fn open_lists_changed_files_and_hunks_since_the_merge_base() {
    let repo = Repo::new();
    repo.write(
        "auth/hash.go",
        "package auth\n\nfunc A() {}\n\nfunc B() {}\n",
    );
    repo.write("old.rs", "fn old() {}\n");
    repo.write(
        "moved.go",
        "package m\n\nfunc One() {}\nfunc Two() {}\nfunc Three() {}\n",
    );
    repo.write("unrelated.txt", "x\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "auth/hash.go",
        "package auth\n\nfunc A() { x() }\n\nfunc B() {}\n",
    );
    repo.write("auth/hash_test.go", "package auth\n");
    repo.write("tests/cli.rs", "#[test]\nfn t() {}\n");
    repo.git(&["rm", "-q", "old.rs"]);
    repo.git(&["mv", "moved.go", "renamed.go"]);
    repo.commit("feature");
    repo.git(&["checkout", "-q", "main"]);
    repo.write("unrelated.txt", "changed on main after branching\n");
    repo.commit("main moves on");

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    assert_eq!(result["files"].as_array().unwrap().len(), 5, "{result}");
    let hash = file(result, "auth/hash.go");
    assert_eq!(hash["status"], "modified");
    assert_eq!(hash["language"], "go");
    assert_eq!(hash["is_test"], false);
    assert_eq!(file(result, "auth/hash_test.go")["is_test"], true);
    assert_eq!(file(result, "auth/hash_test.go")["status"], "added");
    assert_eq!(file(result, "tests/cli.rs")["is_test"], true);
    assert_eq!(file(result, "tests/cli.rs")["language"], "rust");
    assert_eq!(file(result, "old.rs")["status"], "deleted");
    let renamed = file(result, "renamed.go");
    assert_eq!(renamed["status"], "renamed");
    assert_eq!(renamed["old_path"], "moved.go");

    let hunks = hunks_of(result, "auth/hash.go");
    assert_eq!(hunks.len(), 1);
    assert_eq!(hunks[0]["old"], json!({ "start": 3, "len": 1 }));
    assert_eq!(hunks[0]["new"], json!({ "start": 3, "len": 1 }));
    assert_eq!(hunks_of(result, "old.rs").len(), 1);
    assert!(hunks_of(result, "renamed.go").is_empty());
}

#[test]
fn hunk_ids_survive_line_shifts_from_other_hunks() {
    let repo = Repo::new();
    let lines: String = (1..=20).map(|i| format!("line {i}\n")).collect();
    repo.write("a.go", &lines);
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "v1"]);
    repo.write("a.go", &lines.replace("line 15\n", "line fifteen\n"));
    repo.commit("v1");
    repo.git(&["checkout", "-q", "-b", "v2"]);
    repo.write(
        "a.go",
        &format!("new top\n{}", lines.replace("line 15\n", "line fifteen\n")),
    );
    repo.commit("v2");

    let v1 = open(&repo, "main", "v1");
    let v2 = open(&repo, "main", "v2");
    let v1_hunks = hunks_of(&v1["result"], "a.go");
    let v2_hunks = hunks_of(&v2["result"], "a.go");

    assert_eq!(v1_hunks.len(), 1);
    assert_eq!(v2_hunks.len(), 2);
    let moved = v2_hunks.iter().find(|h| h["new"]["start"] == 16).unwrap();
    assert_eq!(moved["id"], v1_hunks[0]["id"]);
    assert_ne!(v2_hunks[0]["id"], v2_hunks[1]["id"]);
}

#[test]
fn identical_hunks_in_one_file_get_distinct_ids() {
    let repo = Repo::new();
    repo.write("a.go", "a\nb\nc\nd\ne\nf\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write("a.go", "a\nx\nb\nc\nd\ne\nx\nf\n");
    repo.commit("feature");

    let response = open(&repo, "main", "feature");
    let hunks = hunks_of(&response["result"], "a.go");

    assert_eq!(hunks.len(), 2);
    assert_ne!(hunks[0]["id"], hunks[1]["id"]);
}

#[test]
fn whitespace_only_changes_are_ignored() {
    let repo = Repo::new();
    repo.write("a.go", "func A() {\n\treturn\n}\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write("a.go", "func A() {\n    return\n}\n");
    repo.commit("feature");

    let response = open(&repo, "main", "feature");

    assert_eq!(response["result"], json!({ "files": [], "hunks": [] }));
}

#[test]
fn errors_are_reported_per_request_and_the_server_keeps_going() {
    let repo = Repo::new();
    repo.write("a.go", "a\n");
    repo.commit("base");

    let responses = serve(&[
        json!({ "jsonrpc": "2.0", "id": 1, "method": "nope" }),
        json!({ "jsonrpc": "2.0", "id": 2, "method": "open", "params": {} }),
        json!({ "jsonrpc": "2.0", "id": 3, "method": "open",
                "params": { "repo": repo.path(), "base": "main", "head": "missing" } }),
        json!({ "jsonrpc": "2.0", "id": 4, "method": "open",
                "params": { "repo": repo.path(), "base": "--output=/tmp/x", "head": "main" } }),
        json!({ "jsonrpc": "2.0", "method": "open",
                "params": { "repo": repo.path(), "base": "main", "head": "main" } }),
        json!({ "jsonrpc": "2.0", "id": 5, "method": "open",
                "params": { "repo": repo.path(), "base": "main", "head": "main" } }),
    ]);

    let codes: Vec<_> = responses
        .iter()
        .map(|r| r["error"]["code"].clone())
        .collect();
    assert_eq!(
        codes,
        [
            json!(-32601),
            json!(-32602),
            json!(1),
            json!(1),
            Value::Null
        ]
    );
    assert_eq!(responses[4]["id"], 5);
    assert_eq!(responses[4]["result"], json!({ "files": [], "hunks": [] }));
}

#[test]
fn malformed_json_gets_a_parse_error() {
    let mut child = Command::new(env!("CARGO_BIN_EXE_trail"))
        .arg("serve")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(), "{{not json").unwrap();
    let out = child.wait_with_output().unwrap();
    let response: Value = serde_json::from_slice(&out.stdout).unwrap();

    assert_eq!(response["id"], Value::Null);
    assert_eq!(response["error"]["code"], -32700);
}
