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

fn assert_no_changes(result: &Value) {
    for key in ["files", "hunks", "nodes"] {
        assert_eq!(result[key], json!([]), "{key} in {result}");
    }
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

    assert_no_changes(&response["result"]);
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
    assert_no_changes(&responses[4]["result"]);
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

fn node<'a>(result: &'a Value, id: &str) -> &'a Value {
    result["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["id"] == id)
        .unwrap_or_else(|| panic!("{id} not in {}", result["nodes"]))
}

fn node_ids(result: &Value) -> Vec<&str> {
    let mut ids: Vec<&str> = result["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["id"].as_str().unwrap())
        .collect();
    ids.sort_unstable();
    ids
}

#[test]
fn go_nodes_are_the_changed_functions_and_methods() {
    let repo = Repo::new();
    repo.write(
        "auth/hash.go",
        "package auth\n\nimport \"fmt\"\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n\nfunc Unchanged() {}\n\nfunc Gone() {}\n\ntype Store struct{}\n\nfunc (s *Store) Load() {}\n",
    );
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "auth/hash.go",
        "package auth\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\nfunc VerifyHash(h string) bool {\n\treturn len(h) == 64\n}\n\nfunc Unchanged() {}\n\ntype Store struct{}\n\nfunc (s *Store) Load() {}\n\nfunc (s *Store) Save() { fmt.Println(strings.ToUpper(\"x\")) }\n",
    );
    repo.write(
        "auth/hash_test.go",
        "package auth\n\nfunc TestVerifyHash(t *testing.T) {}\n",
    );
    repo.commit("feature");

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    assert_eq!(
        node_ids(result),
        [
            "go:auth.Gone",
            "go:auth.Store.Save",
            "go:auth.TestVerifyHash",
            "go:auth.VerifyHash"
        ]
    );
    let verify = node(result, "go:auth.VerifyHash");
    assert_eq!(verify["status"], "modified");
    assert_eq!(verify["kind"], "function");
    assert_eq!(verify["file"], "auth/hash.go");
    assert_eq!(verify["old"], json!({ "start": 5, "len": 3 }));
    assert_eq!(verify["new"], json!({ "start": 8, "len": 3 }));
    let changed_line = hunks_of(result, "auth/hash.go")
        .into_iter()
        .find(|h| h["new"]["start"] == 9)
        .unwrap();
    assert_eq!(verify["hunks"], json!([changed_line["id"]]));
    assert_eq!(node(result, "go:auth.Gone")["status"], "removed");
    assert_eq!(node(result, "go:auth.Gone")["new"], Value::Null);
    let save = node(result, "go:auth.Store.Save");
    assert_eq!(save["status"], "added");
    assert_eq!(save["kind"], "method");
    assert_eq!(save["old"], Value::Null);
    assert_eq!(node(result, "go:auth.TestVerifyHash")["is_test"], true);
    assert_eq!(verify["is_test"], false);

    let in_nodes: Vec<&Value> = result["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|n| n["hunks"].as_array().unwrap())
        .collect();
    let import_hunk = hunks_of(result, "auth/hash.go")
        .into_iter()
        .find(|h| h["new"]["start"] == 3)
        .unwrap();
    assert!(
        !in_nodes.contains(&&import_hunk["id"]),
        "import change is in no function"
    );
}

#[test]
fn rust_nodes_are_named_by_module_impl_and_inline_mod() {
    let repo = Repo::new();
    let base = "pub struct Hasher;\n\nimpl Hasher {\n    pub fn new() -> Self {\n        Hasher\n    }\n}\n\nimpl Default for Hasher {\n    fn default() -> Self {\n        Hasher::new()\n    }\n}\n\npub fn verify(h: &str) -> bool {\n    !h.is_empty()\n}\n\npub fn untouched() {}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn verifies() {}\n}\n";
    repo.write("src/auth/hash.rs", base);
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "src/auth/hash.rs",
        &base
            .replace("        Hasher\n", "        let h = Hasher;\n        h\n")
            .replace("Hasher::new()", "Self::new()")
            .replace("!h.is_empty()", "h.len() == 64")
            .replace(
                "fn verifies() {}",
                "fn verifies() {\n        assert!(super::verify(\"\"));\n    }",
            ),
    );
    repo.write("src/lib.rs", "pub mod auth;\n\npub fn run() {}\n");
    repo.commit("feature");

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    assert_eq!(
        node_ids(result),
        [
            "rust:auth::hash::Hasher::default",
            "rust:auth::hash::Hasher::new",
            "rust:auth::hash::tests::verifies",
            "rust:auth::hash::verify",
            "rust:run",
        ]
    );
    assert_eq!(
        node(result, "rust:auth::hash::Hasher::new")["kind"],
        "method"
    );
    assert_eq!(node(result, "rust:auth::hash::verify")["kind"], "function");
    assert_eq!(
        node(result, "rust:auth::hash::verify")["status"],
        "modified"
    );
    assert_eq!(
        node(result, "rust:auth::hash::tests::verifies")["is_test"],
        true
    );
    assert_eq!(node(result, "rust:auth::hash::verify")["is_test"], false);
    assert_eq!(node(result, "rust:run")["status"], "added");
}

#[test]
fn repeated_go_init_functions_get_distinct_ids() {
    let repo = Repo::new();
    repo.write(
        "p.go",
        "package p\n\nfunc init() {\n\ta()\n}\n\nfunc init() {\n\tb()\n}\n",
    );
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "p.go",
        "package p\n\nfunc init() {\n\ta()\n}\n\nfunc init() {\n\tc()\n}\n",
    );
    repo.commit("feature");

    let response = open(&repo, "main", "feature");

    assert_eq!(node_ids(&response["result"]), ["go:p.init#2"]);
}

#[test]
fn deleting_lines_inside_a_function_marks_it_modified() {
    let repo = Repo::new();
    repo.write("p.go", "package p\n\nfunc F() {\n\ta()\n\tb()\n}\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write("p.go", "package p\n\nfunc F() {\n\ta()\n}\n");
    repo.commit("feature");

    let response = open(&repo, "main", "feature");
    let f = node(&response["result"], "go:p.F");

    assert_eq!(f["status"], "modified");
    assert_eq!(f["hunks"].as_array().unwrap().len(), 1);
}
