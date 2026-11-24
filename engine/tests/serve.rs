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
    serve_with_env(requests, &[])
}

fn serve_with_env(requests: &[Value], env: &[(&str, &str)]) -> Vec<Value> {
    let mut child = Command::new(env!("CARGO_BIN_EXE_trail"))
        .arg("serve")
        .envs(env.iter().copied())
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
    open_with_env(repo, base, head, &[])
}

fn open_with_env(repo: &Repo, base: &str, head: &str, env: &[(&str, &str)]) -> Value {
    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "open",
            "params": { "repo": repo.path(), "base": base, "head": head },
        })],
        env,
    );
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

    assert_eq!(node_ids(&response["result"]), ["go:p.init@p.go#2"]);
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

/// Call edges only; `use` edges to types and constants are checked separately.
fn edges(result: &Value) -> Vec<(String, String, String)> {
    edges_of_kind(result, "call")
}

fn edges_of_kind(result: &Value, kind: &str) -> Vec<(String, String, String)> {
    let mut edges: Vec<_> = result["edges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == kind)
        .map(|e| {
            assert_eq!(e["source"], "name_match");
            (
                e["from"].as_str().unwrap().to_string(),
                e["to"].as_str().unwrap().to_string(),
                e["status"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    edges.sort();
    edges
}

fn edge(from: &str, to: &str, status: &str) -> (String, String, String) {
    (from.to_string(), to.to_string(), status.to_string())
}

#[test]
fn go_edges_compare_calls_before_and_after() {
    let repo = Repo::new();
    repo.write(
        "auth.go",
        "package auth\n\nfunc Login(u string) bool {\n\tGone()\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n\nfunc Gone() {}\n",
    );
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "auth.go",
        "package auth\n\nfunc Login(u string) bool {\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn hashOf(h) == h && VerifyHash(\"\")\n}\n\nfunc hashOf(h string) string { return h }\n",
    );
    repo.commit("feature");

    let response = open(&repo, "main", "feature");

    assert_eq!(
        edges(&response["result"]),
        [
            edge("go:auth.Login", "go:auth.Gone", "removed"),
            edge("go:auth.Login", "go:auth.VerifyHash", "unchanged"),
            edge("go:auth.VerifyHash", "go:auth.hashOf", "added"),
        ]
    );
}

#[test]
fn rust_edges_use_the_qualifier_to_pick_between_same_named_functions() {
    let repo = Repo::new();
    repo.write("README.md", "x\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "src/lib.rs",
        "pub struct A;\npub struct B;\n\nimpl A {\n    pub fn new() -> Self { A }\n    pub fn make() -> Self { Self::new() }\n}\n\nimpl B {\n    pub fn new() -> Self { B }\n    pub fn check(&self) -> bool { true }\n    pub fn run(&self) -> bool { self.check() }\n}\n\npub fn build() -> B { B::new() }\n",
    );
    repo.commit("feature");

    let response = open(&repo, "main", "feature");

    assert_eq!(
        edges(&response["result"]),
        [
            edge("rust:A::make", "rust:A::new", "added"),
            edge("rust:B::run", "rust:B::check", "added"),
            edge("rust:build", "rust:B::new", "added"),
        ]
    );
}

#[test]
fn rust_calls_match_only_what_their_syntax_allows() {
    let repo = Repo::new();
    repo.write("README.md", "x\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "src/lib.rs",
        "pub struct Fnv;\n\nimpl Fnv {\n    pub fn new() -> Self { Fnv }\n}\n\npub fn push() {}\n\npub fn parse() {\n    let mut v = Vec::new();\n    v.push(1);\n    helper();\n}\n\n#[cfg(test)]\nmod tests {\n    pub fn helper() {}\n}\n",
    );
    repo.commit("feature");

    let response = open(&repo, "main", "feature");

    assert_eq!(edges(&response["result"]), []);
}

#[test]
fn go_selector_calls_reach_package_functions_and_methods() {
    let repo = Repo::new();
    repo.write("README.md", "x\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "auth/auth.go",
        "package auth\n\nfunc Verify() bool { return true }\n\nfunc Contains() {}\n\ntype Store struct{}\n\nfunc (s *Store) Save() {}\n",
    );
    repo.write(
        "api/api.go",
        "package api\n\nfunc Handle(s *auth.Store) {\n\tauth.Verify()\n\ts.Save()\n\tstrings.Contains(\"a\", \"b\")\n\tContains()\n}\n",
    );
    repo.commit("feature");

    let response = open(&repo, "main", "feature");

    assert_eq!(
        edges(&response["result"]),
        [
            edge("go:api.Handle", "go:auth.Store.Save", "added"),
            edge("go:api.Handle", "go:auth.Verify", "added"),
        ]
    );
}

const OLD_AUTH: &str = "package auth\n\nimport \"fmt\"\n\nfunc Login(u string) bool {\n\tGone()\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n\nfunc Gone() {}\n";
const NEW_AUTH: &str = "package auth\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\nfunc Login(user string) bool {\n\treturn VerifyHash(user)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn hashOf(h) == h\n}\n\nfunc hashOf(h string) string { return strings.ToLower(h) }\n";

fn branch_with(old: &[(&str, &str)], new: &[(&str, &str)], remove: &[&str]) -> (Repo, Value) {
    let repo = Repo::new();
    repo.write("README.md", "x\n");
    for (path, content) in old {
        repo.write(path, content);
    }
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    for (path, content) in new {
        repo.write(path, content);
    }
    for path in remove {
        repo.git(&["rm", "-q", path]);
    }
    repo.commit("feature");
    let review = open(&repo, "main", "feature")["result"].clone();
    (repo, review)
}

fn file_diff(
    repo: &Repo,
    review: &Value,
    old_path: Option<&str>,
    new_path: Option<&str>,
    env: &[(&str, &str)],
) -> Value {
    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "file_diff",
            "params": {
                "repo": repo.path(),
                "base_commit": review["base_commit"],
                "head_commit": review["head_commit"],
                "old_path": old_path,
                "new_path": new_path,
            },
        })],
        env,
    );
    let result = responses[0]["result"].clone();
    assert!(result.is_object(), "{}", responses[0]);
    assert_rows_cover_every_line_once(&result);
    result
}

fn assert_rows_cover_every_line_once(result: &Value) {
    for (side, lines) in [(0, "old_lines"), (1, "new_lines")] {
        let seen: Vec<u64> = result["rows"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|row| row[side].as_u64())
            .collect();
        let expected: Vec<u64> = (1..=result[lines].as_array().unwrap().len() as u64).collect();
        assert_eq!(seen, expected, "{lines} in rows {}", result["rows"]);
    }
}

fn changes(result: &Value, side: &str, line: u64) -> Option<Value> {
    result[side]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["line"] == line)
        .map(|c| c["spans"].clone())
}

#[test]
fn file_diff_aligns_lines_and_marks_changed_tokens_with_difftastic() {
    let (repo, review) = branch_with(&[("auth.go", OLD_AUTH)], &[("auth.go", NEW_AUTH)], &[]);

    let result = file_diff(&repo, &review, Some("auth.go"), Some("auth.go"), &[]);

    assert_eq!(result["engine"], "difftastic");
    assert_eq!(result["old_lines"][4], "func Login(u string) bool {");
    assert_eq!(result["new_lines"][7], "func Login(user string) bool {");
    let rows = result["rows"].as_array().unwrap();
    assert!(
        rows.contains(&json!([5, 8])),
        "Login lines pair up: {}",
        result["rows"]
    );
    assert!(
        rows.contains(&json!([null, 5])),
        "added import line is filler on the left"
    );
    assert!(
        rows.contains(&json!([6, null])),
        "removed Gone() call is filler on the right"
    );
    assert_eq!(changes(&result, "old_changes", 5), Some(json!([[11, 12]])));
    assert_eq!(changes(&result, "new_changes", 8), Some(json!([[11, 15]])));
    assert_eq!(changes(&result, "new_changes", 1), None);
}

#[test]
fn file_diff_reports_formatting_only_changes_as_unchanged() {
    let (repo, review) = branch_with(
        &[("a.go", "package a\n\nfunc A() { return }\n")],
        &[("a.go", "package a\n\nfunc A() {\n\treturn\n}\n")],
        &[],
    );

    let result = file_diff(&repo, &review, Some("a.go"), Some("a.go"), &[]);

    assert_eq!(result["engine"], "difftastic");
    assert_eq!(result["old_changes"], json!([]));
    assert_eq!(result["new_changes"], json!([]));
    assert_eq!(
        result["rows"],
        json!([[1, 1], [2, 2], [3, 3], [null, 4], [null, 5]])
    );
}

#[test]
fn file_diff_falls_back_to_a_line_diff_without_difftastic() {
    let (repo, review) = branch_with(&[("auth.go", OLD_AUTH)], &[("auth.go", NEW_AUTH)], &[]);

    let result = file_diff(
        &repo,
        &review,
        Some("auth.go"),
        Some("auth.go"),
        &[("TRAIL_DIFFT", "/nonexistent/difft")],
    );

    assert_eq!(result["engine"], "text");
    let rows = result["rows"].as_array().unwrap();
    assert!(
        rows.contains(&json!([7, null])),
        "git pairs the replaced block in order: {}",
        result["rows"]
    );
    assert!(
        rows.contains(&json!([12, 14])),
        "unchanged lines after it pair up"
    );
    let line = NEW_AUTH.lines().nth(7).unwrap();
    let indent = line.len() - line.trim_start().len();
    assert_eq!(
        changes(&result, "new_changes", 8),
        Some(json!([[indent, line.len()]])),
        "a changed line is marked from its first character to its end"
    );
    assert_eq!(changes(&result, "new_changes", 1), None);
}

#[test]
fn file_diff_shows_added_and_deleted_files_against_filler() {
    let (repo, review) = branch_with(
        &[("gone.go", "package a\n\nfunc G() {}\n")],
        &[("new.go", "package a\n")],
        &["gone.go"],
    );

    let added = file_diff(&repo, &review, None, Some("new.go"), &[]);
    let deleted = file_diff(&repo, &review, Some("gone.go"), None, &[]);

    assert_eq!(added["rows"], json!([[null, 1]]));
    assert_eq!(
        added["new_changes"],
        json!([{ "line": 1, "spans": [[0, 9]] }]),
        "every line of an added file is marked as changed text"
    );
    assert_eq!(deleted["rows"], json!([[1, null], [2, null], [3, null]]));
    assert_eq!(
        deleted["old_changes"],
        json!([
            { "line": 1, "spans": [[0, 9]] },
            { "line": 2, "spans": [] },
            { "line": 3, "spans": [[0, 11]] },
        ])
    );
}

#[test]
fn file_diff_keeps_difftastic_alignment_past_its_size_limit() {
    let (repo, review) = branch_with(&[("auth.go", OLD_AUTH)], &[("auth.go", NEW_AUTH)], &[]);

    let result = file_diff(
        &repo,
        &review,
        Some("auth.go"),
        Some("auth.go"),
        &[("DFT_BYTE_LIMIT", "10")],
    );

    assert_eq!(result["engine"], "difftastic");
    for side in ["old_changes", "new_changes"] {
        for change in result[side].as_array().unwrap() {
            for span in change["spans"].as_array().unwrap() {
                assert!(
                    span[0].as_u64() < span[1].as_u64(),
                    "empty span in {change}"
                );
            }
        }
    }
}

#[test]
fn file_diff_fallback_places_pure_insertions_and_deletions() {
    let (repo, review) = branch_with(
        &[("a.txt", "a\nb\nc\nd\n")],
        &[("a.txt", "a\nx\nb\nd\n")],
        &[],
    );

    let result = file_diff(
        &repo,
        &review,
        Some("a.txt"),
        Some("a.txt"),
        &[("TRAIL_DIFFT", "/nonexistent/difft")],
    );

    assert_eq!(
        result["rows"],
        json!([[1, 1], [null, 2], [2, 3], [3, null], [4, 4]])
    );
}

fn formatting_repo() -> Repo {
    let repo = Repo::new();
    repo.write(
        "a.go",
        "package a\n\nfunc Reformatted() { return }\n\nfunc Changed() int {\n\treturn 1\n}\n",
    );
    repo.write("b.go", "package a\n\nfunc B() { return }\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "a.go",
        "package a\n\nfunc Reformatted() {\n\treturn\n}\n\nfunc Changed() int {\n\treturn 2\n}\n",
    );
    repo.write("b.go", "package a\n\nfunc B() {\n\treturn\n}\n");
    repo.commit("feature");
    repo
}

#[test]
fn formatting_only_changes_are_left_out_of_the_review() {
    let repo = formatting_repo();

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    assert_eq!(node_ids(result), ["go:a.Changed"]);
    let paths: Vec<&Value> = result["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| &f["path"])
        .collect();
    assert_eq!(paths, [&json!("a.go")]);
    let hunks = result["hunks"].as_array().unwrap();
    assert_eq!(hunks.len(), 1, "{}", result["hunks"]);
    assert_eq!(
        node(result, "go:a.Changed")["hunks"],
        json!([hunks[0]["id"]])
    );
}

#[test]
fn without_difftastic_formatting_changes_count_like_git_says() {
    let repo = formatting_repo();

    let response = open_with_env(
        &repo,
        "main",
        "feature",
        &[("TRAIL_DIFFT", "/nonexistent/difft")],
    );
    let result = &response["result"];

    assert_eq!(
        node_ids(result),
        ["go:a.B", "go:a.Changed", "go:a.Reformatted"]
    );
    assert_eq!(result["files"].as_array().unwrap().len(), 2);
}

fn peek(
    repo: &Repo,
    commit: &Value,
    language: &str,
    name: &str,
    qualifier: Option<&str>,
    from: &str,
) -> Value {
    let responses = serve(&[json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "peek",
        "params": {
            "repo": repo.path(),
            "commit": commit,
            "language": language,
            "name": name,
            "qualifier": qualifier,
            "from_path": from,
        },
    })]);
    responses.into_iter().next().unwrap()
}

fn match_names(response: &Value) -> Vec<String> {
    response["result"]["matches"]
        .as_array()
        .unwrap_or_else(|| panic!("{response}"))
        .iter()
        .map(|m| {
            format!(
                "{}:{}",
                m["path"].as_str().unwrap(),
                m["name"].as_str().unwrap()
            )
        })
        .collect()
}

#[test]
fn peek_shows_a_function_as_it_is_at_the_requested_commit() {
    let (repo, review) = branch_with(
        &[
            (
                "auth/auth.go",
                "package auth\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n",
            ),
            (
                "api/api.go",
                "package api\n\nfunc Handle() { auth.VerifyHash(\"x\") }\n",
            ),
        ],
        &[(
            "auth/auth.go",
            "package auth\n\nfunc VerifyHash(h string) bool {\n\treturn hashOf(h) == h\n}\n\nfunc hashOf(h string) string { return h }\n",
        )],
        &[],
    );

    let head = peek(
        &repo,
        &review["head_commit"],
        "go",
        "VerifyHash",
        Some("auth"),
        "api/api.go",
    );
    let base = peek(
        &repo,
        &review["base_commit"],
        "go",
        "VerifyHash",
        Some("auth"),
        "api/api.go",
    );
    let new_only = peek(
        &repo,
        &review["base_commit"],
        "go",
        "hashOf",
        None,
        "auth/auth.go",
    );

    let first = &head["result"]["matches"][0];
    assert_eq!(first["path"], "auth/auth.go");
    assert_eq!(first["name"], "auth.VerifyHash");
    assert_eq!(first["kind"], "function");
    assert_eq!(
        (first["start"].as_u64(), first["end"].as_u64()),
        (Some(3), Some(5))
    );
    assert_eq!(
        first["lines"],
        json!([
            "func VerifyHash(h string) bool {",
            "\treturn hashOf(h) == h",
            "}"
        ])
    );
    assert_eq!(
        base["result"]["matches"][0]["lines"][1],
        "\treturn h != \"\""
    );
    assert_eq!(match_names(&new_only), Vec::<String>::new());
}

#[test]
fn peek_ranks_the_qualified_type_then_the_same_file_first() {
    let (repo, review) = branch_with(
        &[],
        &[
            (
                "src/a.rs",
                "pub struct A;\n\nimpl A {\n    pub fn new() -> Self { A }\n}\n",
            ),
            (
                "src/b.rs",
                "pub struct B;\n\nimpl B {\n    pub fn new() -> Self { B }\n}\n",
            ),
            ("src/c/mod.rs", "pub fn new() {}\n"),
        ],
        &[],
    );
    let head = &review["head_commit"];

    assert_eq!(
        match_names(&peek(&repo, head, "rust", "new", Some("B"), "src/a.rs")),
        [
            "src/b.rs:b::B::new",
            "src/a.rs:a::A::new",
            "src/c/mod.rs:c::new"
        ]
    );
    assert_eq!(
        match_names(&peek(&repo, head, "rust", "new", None, "src/b.rs")),
        [
            "src/b.rs:b::B::new",
            "src/a.rs:a::A::new",
            "src/c/mod.rs:c::new"
        ]
    );
    assert_eq!(
        match_names(&peek(&repo, head, "rust", "new", None, "src/c/other.rs")),
        [
            "src/c/mod.rs:c::new",
            "src/a.rs:a::A::new",
            "src/b.rs:b::B::new"
        ]
    );
}

#[test]
fn peek_rejects_names_that_are_not_identifiers() {
    let (repo, review) = branch_with(&[], &[("a.go", "package a\n")], &[]);

    let response = peek(&repo, &review["head_commit"], "go", "-e", None, "a.go");

    assert_eq!(response["error"]["code"], 1, "{response}");
}

fn checkout(repo: &Repo, commit: &str, cache: &Path) -> Value {
    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "checkout",
            "params": { "repo": repo.path(), "commit": commit },
        })],
        &[("XDG_CACHE_HOME", cache.to_str().unwrap())],
    );
    responses.into_iter().next().unwrap()
}

fn rev(repo: &Repo, rev: &str) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo.path())
        .args(["rev-parse", rev])
        .output()
        .unwrap();
    String::from_utf8(out.stdout).unwrap().trim().to_string()
}

#[test]
fn checkout_uses_the_repository_when_it_is_already_at_the_commit() {
    let (repo, _) = branch_with(&[("a.go", "package a\n")], &[("a.go", "package b\n")], &[]);
    let cache = Repo::new();

    let response = checkout(&repo, "feature", cache.path());

    assert_eq!(response["result"]["worktree"], false, "{response}");
    let path = PathBuf::from(response["result"]["path"].as_str().unwrap());
    assert_eq!(
        path.canonicalize().unwrap(),
        repo.path().canonicalize().unwrap()
    );
}

#[test]
fn checkout_keeps_one_reusable_worktree_for_other_commits() {
    let (repo, _) = branch_with(&[("a.go", "package a\n")], &[("a.go", "package b\n")], &[]);
    repo.git(&["checkout", "-q", "-b", "elsewhere", "main"]);
    repo.write("other.go", "package a\n");
    repo.commit("elsewhere");
    let cache = Repo::new();

    let first = checkout(&repo, "feature", cache.path());
    let path = PathBuf::from(
        first["result"]["path"]
            .as_str()
            .unwrap_or_else(|| panic!("{first}")),
    );
    assert_eq!(first["result"]["worktree"], true);
    assert!(
        path.starts_with(cache.path().join("trail").join("worktrees")),
        "{}",
        path.display()
    );
    assert_eq!(
        std::fs::read_to_string(path.join("a.go")).unwrap(),
        "package b\n"
    );

    std::fs::write(path.join("a.go"), "edited\n").unwrap();
    let second = checkout(&repo, &rev(&repo, "main"), cache.path());
    assert_eq!(second["result"]["path"], first["result"]["path"]);
    assert_eq!(
        std::fs::read_to_string(path.join("a.go")).unwrap(),
        "package a\n"
    );

    let out = Command::new("git")
        .arg("-C")
        .arg(repo.path())
        .args(["worktree", "list"])
        .output()
        .unwrap();
    assert_eq!(String::from_utf8(out.stdout).unwrap().lines().count(), 2);
    assert_eq!(
        rev(&repo, "HEAD"),
        rev(&repo, "elsewhere"),
        "the user's checkout is untouched"
    );
}

fn ids(value: &Value) -> Vec<String> {
    value
        .as_array()
        .unwrap_or_else(|| panic!("not an array: {value}"))
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect()
}

#[test]
fn paths_follow_calls_from_entry_points_with_tests_and_loose_hunks_apart() {
    let (repo, _) = branch_with(
        &[
            (
                "auth/auth.go",
                "package auth\n\nimport \"fmt\"\n\nfunc Login(u string) bool {\n\tAudit(u)\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn h != \"\"\n}\n\nfunc Audit(u string) { fmt.Println(u) }\n",
            ),
            (
                "api/api.go",
                "package api\n\nfunc Handle() int { return 1 }\n",
            ),
            (
                "api/api_test.go",
                "package api\n\nfunc TestHandle(t *testing.T) {}\n",
            ),
        ],
        &[
            (
                "auth/auth.go",
                "package auth\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n)\n\nfunc Login(u string) bool {\n\treturn VerifyHash(u)\n}\n\nfunc VerifyHash(h string) bool {\n\treturn hashOf(h) == h\n}\n\nfunc hashOf(h string) string { return strings.ToLower(fmt.Sprint(h)) }\n",
            ),
            (
                "api/api.go",
                "package api\n\nfunc Handle() int { return 2 }\n",
            ),
            (
                "auth/auth_test.go",
                "package auth\n\nimport \"testing\"\n\nfunc TestLogin(t *testing.T) { Login(\"x\") }\n",
            ),
            (
                "api/api_test.go",
                "package api\n\nimport \"testing\"\n\nfunc TestHandle(t *testing.T) {}\n",
            ),
        ],
        &[],
    );

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    let paths = result["paths"].as_array().unwrap();
    assert_eq!(paths.len(), 2, "{}", result["paths"]);
    assert_eq!(paths[0]["id"], "path:go:auth.Login");
    assert_eq!(paths[0]["title"], "auth.Login");
    assert_eq!(paths[0]["origin"], "graph");
    assert_eq!(
        paths[0]["steps"],
        json!([
            ["go:auth.Login"],
            ["go:auth.VerifyHash"],
            ["go:auth.hashOf"],
            ["go:auth.Audit"]
        ])
    );
    assert_eq!(paths[1]["steps"], json!([["go:api.Handle"]]));

    let all_tests = result["tests"].as_array().unwrap();
    assert_eq!(all_tests.len(), 2, "{}", result["tests"]);
    let api_tests = all_tests
        .iter()
        .find(|t| t["file"] == "api/api_test.go")
        .unwrap();
    assert_eq!(
        api_tests["nodes"],
        json!([]),
        "only the import changed in this test file"
    );
    assert_eq!(api_tests["hunks"].as_array().unwrap().len(), 1);
    let tests: Vec<&Value> = all_tests
        .iter()
        .filter(|t| t["file"] == "auth/auth_test.go")
        .collect();
    assert_eq!(tests[0]["file"], "auth/auth_test.go");
    assert_eq!(ids(&tests[0]["nodes"]), ["go:auth.TestLogin"]);
    assert_eq!(
        ids(&tests[0]["covers"]),
        ["go:auth.Login", "go:auth.VerifyHash", "go:auth.hashOf"]
    );
    assert_eq!(tests[0]["hunks"].as_array().unwrap().len(), 1);
    assert_eq!(ids(&result["uncovered"]), ["go:api.Handle"]);

    let import_hunk = result["hunks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["file"] == "auth/auth.go" && h["new"]["start"] == 3)
        .unwrap();
    assert_eq!(result["unassigned"], json!([import_hunk["id"]]));
}

#[test]
fn paths_share_callees_between_entry_points_and_survive_cycles() {
    let (repo, _) = branch_with(
        &[],
        &[
            (
                "p.go",
                "package p\n\nfunc A() { C() }\n\nfunc B() { C() }\n\nfunc C() {}\n\nfunc X() { Y() }\n\nfunc Y() { X() }\n",
            ),
            (
                "src/lib.rs",
                "pub fn run() { helper() }\n\nfn helper() {}\n\n#[cfg(test)]\nmod tests {\n    #[test]\n    fn runs() { super::run() }\n}\n",
            ),
        ],
        &[],
    );

    let response = open(&repo, "main", "feature");
    let result = &response["result"];
    let paths = result["paths"].as_array().unwrap();
    let by_id = |id: &str| {
        paths
            .iter()
            .find(|p| p["id"] == id)
            .unwrap_or_else(|| panic!("{id} in {}", result["paths"]))
    };

    let shared = by_id("path:go:p.A");
    assert_eq!(ids(&shared["entries"]), ["go:p.A", "go:p.B"]);
    assert_eq!(shared["title"], "p.A, p.B");
    assert_eq!(shared["steps"], json!([["go:p.A"], ["go:p.C"], ["go:p.B"]]));
    assert_eq!(
        by_id("path:go:p.X")["steps"],
        json!([["go:p.X"], ["go:p.Y"]])
    );
    assert_eq!(
        by_id("path:rust:run")["steps"],
        json!([["rust:run"], ["rust:helper"]])
    );

    let tests = result["tests"].as_array().unwrap();
    assert_eq!(tests.len(), 1, "{}", result["tests"]);
    assert_eq!(tests[0]["file"], "src/lib.rs");
    assert_eq!(ids(&tests[0]["nodes"]), ["rust:tests::runs"]);
}

#[test]
fn rust_tests_are_found_by_their_attributes_and_file_names() {
    let lib = "pub fn run() -> u8 {\n    1\n}\n\n#[cfg(test)]\nmod unit {\n    fn setup() {}\n\n    #[test]\n    fn runs() {\n        setup();\n        super::run();\n    }\n}\n\n#[test]\nfn top_level() {\n    run();\n}\n\n#[tokio::test]\nasync fn async_runs() {\n    run();\n}\n";
    let caller = "fn checks() {\n    crate::run();\n}\n";
    let changed = |s: &str| {
        s.replace("    1\n", "    2\n")
            .replace("fn setup() {}", "fn setup() {\n        let _ = 1;\n    }")
            .replace("run();\n", "run();\n    let _ = 1;\n")
    };
    let (repo, _) = branch_with(
        &[
            ("src/lib.rs", lib),
            ("src/hash_test.rs", caller),
            ("src/store/tests.rs", caller),
        ],
        &[
            ("src/lib.rs", &changed(lib)),
            ("src/hash_test.rs", &changed(caller)),
            ("src/store/tests.rs", &changed(caller)),
        ],
        &[],
    );

    let result = &open(&repo, "main", "feature")["result"];
    assert_eq!(file(result, "src/lib.rs")["is_test"], false);
    assert_eq!(file(result, "src/hash_test.rs")["is_test"], true);
    assert_eq!(file(result, "src/store/tests.rs")["is_test"], true);
    let tests: Vec<String> = result["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|n| n["is_test"] == true)
        .map(|n| n["id"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        sorted(tests),
        [
            "rust:async_runs",
            "rust:hash_test::checks",
            "rust:store::tests::checks",
            "rust:top_level",
            "rust:unit::runs",
            "rust:unit::setup",
        ],
        "{result}"
    );
    assert_eq!(ids(&result["paths"][0]["entries"]), ["rust:run"]);
    assert_eq!(result["paths"].as_array().unwrap().len(), 1);
    let inline = result["tests"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["file"] == "src/lib.rs")
        .unwrap();
    assert_eq!(inline["covers"], json!(["rust:run"]));
    assert_eq!(result["uncovered"], json!([]));

    let impact = impact_by_name(&repo, &[]);
    let nodes = impact["paths"][0]["nodes"].as_array().unwrap();
    let flags: Vec<(&str, bool, bool)> = nodes
        .iter()
        .map(|n| {
            (
                n["short"].as_str().unwrap(),
                n["entry"] == true,
                n["is_test"] == true,
            )
        })
        .collect();
    assert_eq!(
        sorted(flags),
        [
            ("async_runs", false, true),
            ("checks", false, true),
            ("checks", false, true),
            ("run", true, false),
            ("runs", false, true),
            ("top_level", false, true),
        ],
        "{impact}"
    );
}

/// A fake `gh` that answers `pr view` for pull request 7 of the bare
/// repository at `remote`, whose head is `head`.
fn fake_gh(dir: &Path, remote: &Path, head: &str) -> PathBuf {
    let script = dir.join("gh");
    let json = format!(
        r#"{{"baseRefName":"main","headRefName":"feature","headRefOid":"{head}","title":"Add hashing","url":"file://{}/pull/7","body":"Hashes passwords.","author":{{"login":"alice"}}}}"#,
        remote.display()
    );
    std::fs::write(
        &script,
        format!("#!/bin/sh\n[ \"$1 $2 $3\" = \"pr view 7\" ] || {{ echo \"no pull request $3\" >&2; exit 1; }}\necho '{json}'\n"),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&script)
        .status()
        .unwrap();
    script
}

#[test]
fn pull_requests_are_fetched_and_reviewed_like_branches() {
    let upstream = Repo::new();
    upstream.write("a.go", "package a\n\nfunc A() int { return 1 }\n");
    upstream.commit("base");
    upstream.git(&["checkout", "-q", "-b", "feature"]);
    upstream.write("a.go", "package a\n\nfunc A() int { return 2 }\n");
    upstream.commit("feature");
    let head = rev(&upstream, "feature");
    upstream.git(&["update-ref", "refs/pull/7/head", &head]);
    upstream.git(&["checkout", "-q", "main"]);
    upstream.git(&["branch", "-D", "feature"]);

    let local = Repo::new();
    local.git(&["fetch", "-q", upstream.path().to_str().unwrap(), "main"]);
    local.git(&["reset", "-q", "--hard", "FETCH_HEAD"]);
    let tools = Repo::new();
    let gh = fake_gh(tools.path(), upstream.path(), &head);
    let env = [("TRAIL_GH", gh.to_str().unwrap())];

    let responses = serve_with_env(
        &[
            json!({ "jsonrpc": "2.0", "id": 1, "method": "pull_request", "params": { "repo": local.path(), "number": 7 } }),
            json!({ "jsonrpc": "2.0", "id": 2, "method": "pull_request", "params": { "repo": local.path(), "number": 8 } }),
        ],
        &env,
    );

    let pr = &responses[0]["result"];
    assert_eq!(pr["number"], 7, "{}", responses[0]);
    assert_eq!(pr["title"], "Add hashing");
    assert_eq!(
        [
            &pr["author"],
            &pr["description"],
            &pr["base_branch"],
            &pr["head_branch"]
        ],
        [
            &json!("alice"),
            &json!("Hashes passwords."),
            &json!("main"),
            &json!("feature")
        ],
        "the overview gets who opened it, its description and its branches"
    );
    assert_eq!(pr["head"], head.as_str());
    assert_eq!(pr["base"], rev(&local, "main").as_str());
    assert_eq!(rev(&local, "refs/trail/pull/7/head"), head);
    let review = open(
        &local,
        pr["base"].as_str().unwrap(),
        pr["head"].as_str().unwrap(),
    );
    assert_eq!(node_ids(&review["result"]), ["go:a.A"]);
    assert_eq!(responses[1]["error"]["code"], 1);
    assert!(
        responses[1]["error"]["message"]
            .as_str()
            .unwrap()
            .contains("no pull request 8"),
        "{}",
        responses[1]
    );
}

fn open_lsp(repo: &Repo, env: &[(&str, &str)]) -> Value {
    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "open",
            "params": { "repo": repo.path(), "base": "main", "head": "feature", "lsp": true },
        })],
        env,
    );
    responses.into_iter().next().unwrap()["result"].clone()
}

fn method_repo() -> Repo {
    let (repo, _) = branch_with(
        &[
            ("go.mod", "module example.com/m\n\ngo 1.22\n"),
            (
                "store/store.go",
                "package store\n\ntype Store struct{ n int }\ntype Cache struct{ n int }\n\nfunc (s *Store) Save() {}\nfunc (c *Cache) Save() {}\n\nfunc Run(s *Store) {\n\ts.Save()\n\tOld()\n}\n\nfunc Old() {}\n",
            ),
        ],
        &[(
            "store/store.go",
            "package store\n\ntype Store struct{ n, m int }\ntype Cache struct{ n int }\n\nfunc (s *Store) Save() { s.n++ }\nfunc (c *Cache) Save() { c.n-- }\n\nfunc Run(s *Store) {\n\ts.Save()\n}\n",
        )],
        &[],
    );
    repo
}

#[test]
fn without_a_language_server_calls_stay_name_matched() {
    let repo = method_repo();

    let result = open_lsp(&repo, &[("TRAIL_GOPLS", "/nonexistent/gopls")]);

    assert_eq!(
        edges(&result),
        [
            edge("go:store.Run", "go:store.Cache.Save", "unchanged"),
            edge("go:store.Run", "go:store.Old", "removed"),
            edge("go:store.Run", "go:store.Store.Save", "unchanged"),
        ]
    );
}

#[test]
fn gopls_call_hierarchy_replaces_name_matched_calls_on_the_head_side() {
    if Command::new("gopls").arg("version").output().is_err() {
        eprintln!("gopls is not installed; skipping");
        return;
    }
    let repo = method_repo();

    let result = open_lsp(&repo, &[]);

    let sources: Vec<(String, String, String)> = result["edges"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == "call")
        .map(|e| {
            (
                e["to"].as_str().unwrap().to_string(),
                e["status"].as_str().unwrap().to_string(),
                e["source"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert_eq!(
        sources,
        [
            (
                "go:store.Store.Save".to_string(),
                "unchanged".to_string(),
                "lsp".to_string()
            ),
            (
                "go:store.Old".to_string(),
                "removed".to_string(),
                "name_match".to_string()
            ),
        ],
        "{}",
        result["edges"]
    );
    assert_eq!(
        edges_of_kind(&result, "use"),
        [
            edge("go:store.Run", "go:store.Store", "unchanged"),
            edge("go:store.Store.Save", "go:store.Store", "unchanged"),
        ],
        "use edges stay after the language server confirms calls"
    );
}

#[test]
fn a_slow_language_server_does_not_hold_up_other_requests() {
    let repo = method_repo();
    let tools = Repo::new();
    let slow = tools.path().join("slow-gopls");
    std::fs::write(&slow, "#!/bin/sh\nsleep 2\n").unwrap();
    Command::new("chmod").arg("+x").arg(&slow).status().unwrap();
    let params =
        |lsp: bool| json!({ "repo": repo.path(), "base": "main", "head": "feature", "lsp": lsp });

    let responses = serve_with_env(
        &[
            json!({ "jsonrpc": "2.0", "id": 1, "method": "open", "params": params(true) }),
            json!({ "jsonrpc": "2.0", "id": 2, "method": "open", "params": params(false) }),
        ],
        &[("TRAIL_GOPLS", slow.to_str().unwrap())],
    );

    let order: Vec<&Value> = responses.iter().map(|r| &r["id"]).collect();
    assert_eq!(
        order,
        [&json!(2), &json!(1)],
        "the quick request is answered first"
    );
    assert!(
        responses[1]["result"]["edges"]
            .as_array()
            .unwrap()
            .iter()
            .all(|e| e["source"] == "name_match")
    );
}

#[test]
fn go_ids_use_the_package_folder_and_keep_init_apart_per_file() {
    let (repo, _) = branch_with(
        &[],
        &[
            (
                "internal/auth/a.go",
                "package auth\n\nfunc VerifyHash() {}\n\nfunc init() {}\n",
            ),
            ("internal/auth/b.go", "package auth\n\nfunc init() {}\n"),
            ("pkg/auth/a.go", "package auth\n\nfunc VerifyHash() {}\n"),
            (
                "api/api.go",
                "package api\n\nfunc Handle() {\n\tauth.VerifyHash()\n\tlocal()\n}\n\nfunc local() {}\n",
            ),
        ],
        &[],
    );

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    assert_eq!(
        node_ids(result),
        [
            "go:api.Handle",
            "go:api.local",
            "go:internal/auth.VerifyHash",
            "go:internal/auth.init@a.go",
            "go:internal/auth.init@b.go",
            "go:pkg/auth.VerifyHash",
        ]
    );
    assert_eq!(
        edges(result),
        [
            edge("go:api.Handle", "go:api.local", "added"),
            edge("go:api.Handle", "go:internal/auth.VerifyHash", "added"),
            edge("go:api.Handle", "go:pkg/auth.VerifyHash", "added"),
        ],
        "a qualified call matches every package whose folder ends in the qualifier"
    );
}

#[test]
fn bare_rust_calls_reach_other_modules_only_through_use() {
    let (repo, _) = branch_with(
        &[],
        &[
            ("src/a.rs", "pub fn run() {}\n"),
            ("src/b.rs", "pub fn run() {}\n\npub fn show() {}\n"),
            ("src/c.rs", "use crate::a::run;\n\npub fn go() { run() }\n"),
            (
                "src/d.rs",
                "use crate::b::{show as display};\n\npub fn go2() { display() }\n",
            ),
            ("src/e.rs", "pub fn go3() { run() }\n"),
            ("src/f.rs", "use super::*;\n\npub fn go4() { show() }\n"),
            ("src/lib.rs", "pub fn top() {}\n"),
            ("src/g.rs", "use crate::top;\n\npub fn go5() { top() }\n"),
            ("src/h.rs", "pub fn top() {}\n"),
        ],
        &[],
    );

    let response = open(&repo, "main", "feature");

    assert_eq!(
        edges(&response["result"]),
        [
            edge("rust:c::go", "rust:a::run", "added"),
            edge("rust:d::go2", "rust:b::show", "added"),
            edge("rust:f::go4", "rust:b::show", "added"),
            edge("rust:g::go5", "rust:top", "added"),
        ]
    );
}

#[test]
fn changed_types_and_constants_pull_in_the_code_that_uses_them() {
    let (repo, _) = branch_with(
        &[
            (
                "store/store.go",
                "package store\n\nconst Limit = 10\n\ntype Store struct {\n\tn int\n}\n\nfunc (s *Store) Save() {}\n\nfunc Other() {}\n",
            ),
            (
                "store/run.go",
                "package store\n\nfunc Run() int { return Limit }\n",
            ),
            ("other/other.go", "package other\n\nconst Limit = 1\n"),
            (
                "store/util.go",
                "package store\n\nimport \"fmt\"\n\nvar _ = fmt.Sprint\n",
            ),
        ],
        &[
            (
                "store/store.go",
                "package store\n\nconst Limit = 20\n\ntype Store struct {\n\tn    int\n\tname string\n}\n\nfunc (s *Store) Save() {}\n\nfunc Other() {}\n",
            ),
            (
                "store/util.go",
                "package store\n\nimport (\n\t\"fmt\"\n\t\"os\"\n)\n\nvar _ = fmt.Sprint\n",
            ),
            ("other/other.go", "package other\n\nconst Limit = 2\n"),
        ],
        &[],
    );

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    assert_eq!(
        node_ids(result),
        [
            "go:other.Limit",
            "go:store.Limit",
            "go:store.Run",
            "go:store.Store",
            "go:store.Store.Save"
        ]
    );
    assert_eq!(node(result, "go:store.Limit")["kind"], "const");
    assert_eq!(node(result, "go:store.Store")["kind"], "type");
    assert_eq!(node(result, "go:store.Store")["status"], "modified");
    assert_eq!(node(result, "go:store.Run")["status"], "context");
    assert_eq!(node(result, "go:store.Run")["file"], "store/run.go");
    assert_eq!(node(result, "go:store.Run")["hunks"], json!([]));
    assert_eq!(node(result, "go:store.Store.Save")["status"], "context");
    assert_eq!(
        edges_of_kind(result, "use"),
        [
            edge("go:store.Run", "go:store.Limit", "unchanged"),
            edge("go:store.Store.Save", "go:store.Store", "unchanged"),
        ]
    );
    let steps: Vec<&Value> = result["paths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| &p["steps"])
        .collect();
    assert!(
        steps.contains(&&json!([["go:store.Run"], ["go:store.Limit"]])),
        "{}",
        result["paths"]
    );
    assert!(
        steps.contains(&&json!([["go:store.Store.Save"], ["go:store.Store"]])),
        "{}",
        result["paths"]
    );
    assert_eq!(
        ids(&result["uncovered"]),
        ["go:other.Limit", "go:store.Limit", "go:store.Store"],
        "context code is not reported as uncovered"
    );
    let util_hunk = result["hunks"]
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["file"] == "store/util.go")
        .unwrap();
    assert_eq!(
        result["unassigned"],
        json!([util_hunk["id"]]),
        "an import-only change stays out of the nodes"
    );
}

#[test]
fn open_and_file_diff_do_not_need_the_git_command() {
    let (repo, _) = branch_with(&[("auth.go", OLD_AUTH)], &[("auth.go", NEW_AUTH)], &[]);
    let difft = String::from_utf8(
        Command::new("sh")
            .args(["-c", "command -v difft"])
            .output()
            .unwrap()
            .stdout,
    )
    .unwrap();
    let no_git = [("PATH", "/nonexistent"), ("TRAIL_DIFFT", difft.trim())];

    let responses = serve_with_env(
        &[
            json!({ "jsonrpc": "2.0", "id": 1, "method": "open", "params": { "repo": repo.path(), "base": "main", "head": "feature" } }),
        ],
        &no_git,
    );
    let review = &responses[0]["result"];
    assert_eq!(
        node_ids(review),
        [
            "go:auth.Gone",
            "go:auth.Login",
            "go:auth.VerifyHash",
            "go:auth.hashOf"
        ],
        "{}",
        responses[0]
    );

    let diff = file_diff(&repo, review, Some("auth.go"), Some("auth.go"), &no_git);
    assert_eq!(diff["engine"], "difftastic");
}

#[test]
fn whitespace_only_changes_are_ignored_without_difftastic_too() {
    let repo = Repo::new();
    repo.write("a.go", "func A() {\n\treturn\n}\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write("a.go", "func A() {\n    return  \n}\n");
    repo.commit("feature");

    let responses = serve_with_env(
        &[
            json!({ "jsonrpc": "2.0", "id": 1, "method": "open", "params": { "repo": repo.path(), "base": "main", "head": "feature" } }),
        ],
        &[("TRAIL_DIFFT", "/nonexistent/difft")],
    );

    assert_no_changes(&responses[0]["result"]);
}

#[test]
fn added_and_deleted_files_number_their_empty_side_from_zero() {
    let (repo, _) = branch_with(
        &[("gone.go", "package a\n\nfunc G() {}\n")],
        &[("new.go", "package a\n")],
        &["gone.go"],
    );

    let response = open(&repo, "main", "feature");
    let result = &response["result"];

    assert_eq!(
        hunks_of(result, "new.go")[0]["old"],
        json!({ "start": 0, "len": 0 })
    );
    assert_eq!(
        hunks_of(result, "new.go")[0]["new"],
        json!({ "start": 1, "len": 1 })
    );
    assert_eq!(
        hunks_of(result, "gone.go")[0]["old"],
        json!({ "start": 1, "len": 3 })
    );
    assert_eq!(
        hunks_of(result, "gone.go")[0]["new"],
        json!({ "start": 0, "len": 0 })
    );
}

fn impact_repo() -> Repo {
    let service = "package orders\n\nimport \"example.com/shop/store\"\n\ntype Saver interface {\n\tSave(o store.Order) error\n}\n\ntype Service struct{ saver Saver }\n\nfunc New(s *store.Store) *Service { return &Service{saver: s} }\n\nfunc (s *Service) Create(o store.Order) error {\n\treturn s.saver.Save(o)\n}\n\nfunc (s *Service) Import(os []store.Order) error {\n\tfor _, o := range os {\n\t\tif err := s.Create(o); err != nil {\n\t\t\treturn err\n\t\t}\n\t}\n\treturn nil\n}\n";
    let (repo, _) = branch_with(
        &[
            ("go.mod", "module example.com/shop\n\ngo 1.22\n"),
            (
                "store/store.go",
                "package store\n\ntype Order struct{ ID string }\n\ntype Store struct{ seen map[string]bool }\n\nfunc (s *Store) Save(o Order) error {\n\treturn nil\n}\n\nfunc (s *Store) Reset() {}\n",
            ),
            (
                "store/store_test.go",
                "package store\n\nimport \"testing\"\n\nfunc TestSave(t *testing.T) {\n\t_ = (&Store{}).Save(Order{})\n}\n\nfunc TestReset(t *testing.T) {\n\t(&Store{}).Reset()\n}\n",
            ),
            ("orders/service.go", service),
            (
                "api/api.go",
                "package api\n\nimport (\n\t\"example.com/shop/orders\"\n\t\"example.com/shop/store\"\n)\n\nfunc handleCreateOrder(svc *orders.Service) error {\n\treturn svc.Create(store.Order{ID: \"1\"})\n}\n\nfunc Routes() {\n\tregister(func() {\n\t\t_ = handleCreateOrder(orders.New(&store.Store{}))\n\t})\n}\n\nfunc register(f func()) { f() }\n",
            ),
            (
                "cmd/importer/main.go",
                "package main\n\nimport (\n\t\"example.com/shop/orders\"\n\t\"example.com/shop/store\"\n)\n\nfunc main() {\n\t_ = orders.New(&store.Store{}).Import(nil)\n}\n",
            ),
            (
                "billing/billing.go",
                "package billing\n\nfunc Charge() int {\n\treturn 1\n}\n\nfunc Pay() int {\n\treturn Charge()\n}\n",
            ),
        ],
        &[
            (
                "store/store.go",
                "package store\n\nimport \"errors\"\n\ntype Order struct{ ID string }\n\ntype Store struct{ seen map[string]bool }\n\nvar ErrDuplicate = errors.New(\"duplicate\")\n\nfunc (s *Store) Save(o Order) error {\n\tif s.seen[dedupeKey(o)] {\n\t\treturn ErrDuplicate\n\t}\n\treturn nil\n}\n\nfunc dedupeKey(o Order) string {\n\treturn string(Key(o.ID))\n}\n\nfunc (s *Store) Reset() {\n\ts.seen = nil\n}\n\ntype Key string\n",
            ),
            (
                "api/api.go",
                "package api\n\nimport (\n\t\"errors\"\n\n\t\"example.com/shop/orders\"\n\t\"example.com/shop/store\"\n)\n\nfunc handleCreateOrder(svc *orders.Service) error {\n\terr := svc.Create(store.Order{ID: \"1\"})\n\tif errors.Is(err, store.ErrDuplicate) {\n\t\treturn nil\n\t}\n\treturn err\n}\n\nfunc Routes() {\n\tregister(func() {\n\t\t_ = handleCreateOrder(orders.New(&store.Store{}))\n\t})\n}\n\nfunc register(f func()) { f() }\n",
            ),
            (
                "billing/billing.go",
                "package billing\n\nfunc Charge() int {\n\treturn 2\n}\n\nfunc Pay() int {\n\treturn Charge()\n}\n",
            ),
        ],
        &[],
    );
    repo
}

fn impact_response(repo: &Repo, lsp: bool, env: &[(&str, &str)]) -> Value {
    serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "impact",
            "params": { "repo": repo.path(), "base": "main", "head": "feature", "lsp": lsp },
        })],
        env,
    )
    .remove(0)
}

fn impact(repo: &Repo, env: &[(&str, &str)]) -> Value {
    let response = impact_response(repo, true, env);
    let result = response["result"].clone();
    assert!(result.is_object(), "{response}");
    result
}

/// The impact with the language server turned off, so calls are matched by name.
fn impact_by_name(repo: &Repo, env: &[(&str, &str)]) -> Value {
    let response = impact_response(repo, false, env);
    let result = response["result"].clone();
    assert!(result.is_object(), "{response}");
    result
}

/// A path's edges as (caller, callee, via, source), by function name.
fn impact_edges(path: &Value) -> Vec<(String, String, String, String)> {
    let name = |id: &Value| {
        path["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| &n["id"] == id)
            .map(|n| n["name"].as_str().unwrap().to_string())
            .unwrap_or_else(|| panic!("edge to unknown node {id}"))
    };
    let mut out: Vec<_> = path["edges"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| {
            (
                name(&e["from"]),
                name(&e["to"]),
                e["via"].as_str().unwrap_or("").to_string(),
                e["source"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    out.sort();
    out
}

/// A path's trees as indented rows of function names, `↑` marking a row
/// that joins a tree shown earlier, and `*` a tree with no change before it joins.
fn impact_trees(path: &Value) -> Vec<Vec<String>> {
    let name = |id: &Value| {
        path["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| &n["id"] == id)
            .map(|n| n["name"].as_str().unwrap().to_string())
            .unwrap_or_else(|| panic!("row for unknown node {id}"))
    };
    path["trees"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tree| {
            let mut rows: Vec<String> = tree["rows"]
                .as_array()
                .unwrap()
                .iter()
                .map(|row| {
                    let depth = row["depth"].as_u64().unwrap() as usize;
                    let mut line = format!("{}{}", "  ".repeat(depth), name(&row["id"]));
                    if let Some(via) = row["via"].as_str() {
                        line.push_str(&format!(" via {via}"));
                    }
                    if row["join"] == true {
                        line.push_str(" ↑");
                    }
                    line
                })
                .collect();
            if tree["changes"] == false {
                rows[0].push_str(" *");
            }
            rows
        })
        .collect()
}

fn impact_node<'a>(path: &'a Value, name: &str) -> &'a Value {
    path["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["name"] == name)
        .unwrap_or_else(|| panic!("no node {name} in {}", path["nodes"]))
}

fn sorted<T: Ord>(mut items: Vec<T>) -> Vec<T> {
    items.sort();
    items
}

fn edge4(from: &str, to: &str, via: &str, source: &str) -> (String, String, String, String) {
    (from.into(), to.into(), via.into(), source.into())
}

fn has_gopls() -> bool {
    let found = Command::new("gopls").arg("version").output().is_ok();
    if !found {
        eprintln!("gopls is not installed; skipping");
    }
    found
}

/// The head lines of the calls an edge stands for, by caller and callee name.
fn edge_lines(path: &Value, from: &str, to: &str) -> Vec<u64> {
    let id = |name: &str| impact_node(path, name)["id"].clone();
    let (from, to) = (id(from), id(to));
    let edge = path["edges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["from"] == from && e["to"] == to)
        .unwrap_or_else(|| panic!("no edge {from} -> {to} in {path}"));
    edge["lines"]
        .as_array()
        .unwrap_or_else(|| panic!("edge without lines: {edge}"))
        .iter()
        .map(|l| l.as_u64().unwrap())
        .collect()
}

#[test]
fn impact_edges_carry_the_lines_of_their_calls_when_matching_by_name() {
    let repo = impact_repo();

    let result = impact_by_name(&repo, &[]);

    let paths = &result["paths"];
    assert_eq!(
        edge_lines(&paths[0], "api.handleCreateOrder", "orders.Service.Create"),
        [11],
        "{result}"
    );
    assert_eq!(
        edge_lines(&paths[0], "orders.Service.Create", "store.Store.Save"),
        [14]
    );
    assert_eq!(edge_lines(&paths[1], "billing.Pay", "billing.Charge"), [8]);
}

#[test]
fn impact_edges_carry_the_lines_of_their_calls_from_the_language_server() {
    if !Command::new("rust-analyzer")
        .arg("--version")
        .output()
        .is_ok_and(|o| o.status.success())
    {
        eprintln!("rust-analyzer is not installed; skipping");
        return;
    }
    let lib = "pub mod store;\n\npub fn run() -> u32 {\n    let s = store::Store::new();\n    s.save() + s.save()\n}\n";
    let store = |n: u32| {
        format!(
            "pub struct Store;\n\nimpl Store {{\n    pub fn new() -> Store {{\n        Store\n    }}\n\n    pub fn save(&self) -> u32 {{\n        {n}\n    }}\n}}\n"
        )
    };
    let (repo, _) = branch_with(
        &[
            (
                "Cargo.toml",
                "[package]\nname = \"m\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
            ),
            ("src/lib.rs", lib),
            ("src/store.rs", &store(1)),
        ],
        &[("src/store.rs", &store(2))],
        &[],
    );

    let result = impact(&repo, &[]);

    let path = &result["paths"][0];
    let source = path["edges"][0]["source"].as_str().unwrap_or("");
    if source != "lsp" {
        eprintln!("rust-analyzer did not answer ({source}); skipping");
        return;
    }
    assert_eq!(
        edge_lines(path, "run", "store::Store::save"),
        [5],
        "{result}"
    );
}

#[test]
fn impact_walks_through_unchanged_callers_and_interfaces_with_gopls() {
    if !has_gopls() {
        return;
    }
    let repo = impact_repo();

    let result = impact(&repo, &[]);

    let paths = result["paths"].as_array().unwrap();
    assert_eq!(paths.len(), 3, "{result}");
    let orders = &paths[0];
    assert_eq!(
        orders["steps"],
        json!([
            "go:api.handleCreateOrder",
            "go:store.Store.Save",
            "go:store.dedupeKey",
            "go:store.Key",
            "go:store.ErrDuplicate"
        ]),
        "changes reached through unchanged code share one path, in reading order, types and values below what uses them"
    );
    assert_eq!(
        edge_lines(orders, "api.handleCreateOrder", "orders.Service.Create"),
        [11],
        "edges carry the lines of their calls"
    );
    assert_eq!(
        impact_trees(orders),
        [
            vec![
                "api.Routes",
                "  api.handleCreateOrder",
                "    orders.Service.Create",
                "      store.Store.Save via orders.Saver.Save",
                "        store.dedupeKey",
                "          store.Key",
                "        store.ErrDuplicate",
            ],
            vec![
                "cmd/importer.main *",
                "  orders.Service.Import",
                "    orders.Service.Create ↑",
            ],
        ],
        "a tree per entry point, the one through most changes first, each later one stopping where it joins"
    );
    assert_eq!(
        impact_edges(orders),
        sorted(vec![
            edge4("api.Routes", "api.handleCreateOrder", "", "lsp"),
            edge4(
                "orders.Service.Create",
                "store.Store.Save",
                "orders.Saver.Save",
                "lsp"
            ),
            edge4("orders.Service.Import", "orders.Service.Create", "", "lsp"),
            edge4("store.Store.Save", "store.dedupeKey", "", "lsp"),
            edge4("store.Store.Save", "store.ErrDuplicate", "", "lsp"),
            edge4("store.dedupeKey", "store.Key", "", "lsp"),
            edge4("store.TestSave", "store.Store.Save", "", "lsp"),
            edge4("api.handleCreateOrder", "orders.Service.Create", "", "lsp"),
            edge4("cmd/importer.main", "orders.Service.Import", "", "lsp"),
        ])
    );
    let flags = |name: &str| {
        let n = impact_node(orders, name);
        (
            n["status"].as_str().unwrap().to_string(),
            n["entry"] == true,
            n["is_test"] == true,
        )
    };
    assert_eq!(flags("api.Routes"), ("unchanged".into(), true, false));
    assert_eq!(
        flags("cmd/importer.main"),
        ("unchanged".into(), true, false)
    );
    assert_eq!(
        flags("orders.Service.Create"),
        ("unchanged".into(), false, false)
    );
    assert_eq!(
        flags("store.TestSave"),
        ("unchanged".into(), false, true),
        "a test calling in is not an entry point"
    );
    assert_eq!(flags("store.Store.Save"), ("modified".into(), false, false));
    assert_eq!(flags("store.dedupeKey"), ("added".into(), false, false));
    let short = |name: &str| {
        let n = impact_node(orders, name);
        (n["package"].as_str().unwrap(), n["short"].as_str().unwrap())
    };
    assert_eq!(short("store.Store.Save"), ("store", "Store.Save"));
    assert_eq!(short("store.dedupeKey"), ("store", "dedupeKey"));
    assert_eq!(short("cmd/importer.main"), ("cmd/importer", "main"));
    assert!(
        !orders["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["name"].as_str().unwrap().contains("Routes (")),
        "a closure is part of the function holding it, not a node of its own"
    );
    let create = impact_node(orders, "orders.Service.Create");
    assert_eq!(
        (create["file"].as_str(), create["line"].as_u64()),
        (Some("orders/service.go"), Some(13))
    );
    assert_eq!(orders["truncated"], false);

    let billing = &paths[1];
    assert_eq!(billing["steps"], json!(["go:billing.Charge"]));
    assert_eq!(
        impact_edges(billing),
        [edge4("billing.Pay", "billing.Charge", "", "lsp")]
    );
    let reset = &paths[2];
    assert_eq!(
        impact_node(reset, "store.Store.Reset")["entry"],
        true,
        "a function only tests call is an entry point: {reset}"
    );
}

#[test]
fn impact_with_lsp_off_never_starts_the_language_server() {
    let repo = impact_repo();
    let tools = Repo::new();
    let started = tools.path().join("started");
    let gopls = tools.path().join("gopls");
    std::fs::write(
        &gopls,
        format!(
            "#!/bin/sh\ntouch '{}'\nexec gopls \"$@\"\n",
            started.display()
        ),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&gopls)
        .status()
        .unwrap();

    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "impact",
            "params": { "repo": repo.path(), "base": "main", "head": "feature", "lsp": false },
        })],
        &[("TRAIL_GOPLS", gopls.to_str().unwrap())],
    );

    let paths = responses[0]["result"]["paths"].as_array().unwrap();
    assert_eq!(paths.len(), 3, "{}", responses[0]);
    assert!(!started.exists(), "the language server was started");
    assert!(
        impact_edges(&paths[0])
            .iter()
            .all(|(_, _, _, source)| source == "name_match"),
        "calls are matched by name: {:?}",
        impact_edges(&paths[0])
    );
}

#[test]
fn with_the_language_server_off_impact_matches_calls_by_name() {
    let repo = impact_repo();

    let result = impact_by_name(&repo, &[]);

    let paths = result["paths"].as_array().unwrap();
    assert_eq!(paths.len(), 3, "{result}");
    assert_eq!(
        paths[0]["steps"],
        json!([
            "go:api.handleCreateOrder",
            "go:store.Store.Save",
            "go:store.dedupeKey",
            "go:store.Key",
            "go:store.ErrDuplicate"
        ])
    );
    assert_eq!(
        impact_edges(&paths[0]),
        sorted(vec![
            edge4("api.Routes", "api.handleCreateOrder", "", "name_match"),
            edge4(
                "orders.Service.Create",
                "store.Store.Save",
                "",
                "name_match"
            ),
            edge4(
                "orders.Service.Import",
                "orders.Service.Create",
                "",
                "name_match"
            ),
            edge4("store.Store.Save", "store.dedupeKey", "", "name_match"),
            edge4("store.Store.Save", "store.ErrDuplicate", "", "name_match"),
            edge4("store.dedupeKey", "store.Key", "", "name_match"),
            edge4("store.TestSave", "store.Store.Save", "", "name_match"),
            edge4(
                "api.handleCreateOrder",
                "orders.Service.Create",
                "",
                "name_match"
            ),
            edge4(
                "cmd/importer.main",
                "orders.Service.Import",
                "",
                "name_match"
            ),
        ])
    );
    assert_eq!(impact_node(&paths[0], "api.Routes")["entry"], true);
    assert_eq!(
        impact_edges(&paths[1]),
        [edge4("billing.Pay", "billing.Charge", "", "name_match")]
    );
    assert_eq!(impact_node(&paths[2], "store.Store.Reset")["entry"], true);
}

#[test]
fn the_impact_walk_stops_at_the_node_limit_and_says_so() {
    let repo = impact_repo();

    let result = impact_by_name(&repo, &[("TRAIL_IMPACT_LIMIT", "2")]);

    let paths = result["paths"].as_array().unwrap();
    let billing = paths
        .iter()
        .find(|p| p["steps"] == json!(["go:billing.Charge"]))
        .expect("billing path");
    assert_eq!(billing["truncated"], false, "{result}");
    assert!(
        paths
            .iter()
            .filter(|p| p["steps"].to_string().contains("go:store.Store.Save")
                || p["steps"].to_string().contains("go:api.handleCreateOrder"))
            .all(|p| p["truncated"] == true),
        "{result}"
    );
}

#[test]
fn the_impact_walk_stops_at_the_time_limit_and_says_so() {
    let repo = impact_repo();

    let result = impact_by_name(&repo, &[("TRAIL_IMPACT_TIMEOUT", "0")]);

    let paths = result["paths"].as_array().unwrap();
    assert!(!paths.is_empty(), "{result}");
    assert!(paths.iter().all(|p| p["truncated"] == true), "{result}");
}

/// A language server that starts but never finds anything, like gopls on a
/// module it cannot load.
const EMPTY_LSP: &str = r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    Content-Length:*) len=$(printf '%s' "${line#Content-Length: }" | tr -d '\r') ;;
    "$(printf '\r')")
      body=$(dd bs=1 count="$len" 2>/dev/null)
      id=$(printf '%s' "$body" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
      if [ -n "$id" ]; then
        case "$body" in
          *'"method":"initialize"'*) result='{"capabilities":{}}' ;;
          *prepareCallHierarchy*) result='[]' ;;
          *) result=null ;;
        esac
        out="{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":$result}"
        printf 'Content-Length: %d\r\n\r\n%s' "${#out}" "$out"
      fi ;;
  esac
done
"#;

#[test]
fn a_language_server_that_never_finds_anything_fails_the_impact_and_says_so() {
    let repo = impact_repo();
    let tools = Repo::new();
    let server = tools.path().join("empty-lsp");
    std::fs::write(&server, EMPTY_LSP).unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&server)
        .status()
        .unwrap();

    let started = std::time::Instant::now();
    let response = impact_response(
        &repo,
        true,
        &[
            ("TRAIL_GOPLS", server.to_str().unwrap()),
            ("TRAIL_LSP_TIMEOUT", "2"),
            ("TRAIL_IMPACT_TIMEOUT", "15"),
        ],
    );

    assert!(
        started.elapsed() < std::time::Duration::from_secs(10),
        "gives up on the server after its own timeout, not the walk's"
    );
    let message = response["error"]["message"].as_str().unwrap_or_default();
    assert!(
        message.starts_with(
            "go language server failed: go language server found none of the changed functions in "
        ),
        "{response}"
    );
}

#[test]
fn waiting_for_the_language_server_to_load_does_not_count_against_the_walk_time_limit() {
    let repo = impact_repo();
    let tools = Repo::new();
    let server = tools.path().join("empty-lsp");
    std::fs::write(&server, EMPTY_LSP).unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&server)
        .status()
        .unwrap();

    let started = std::time::Instant::now();
    let response = impact_response(
        &repo,
        true,
        &[
            ("TRAIL_GOPLS", server.to_str().unwrap()),
            ("TRAIL_LSP_TIMEOUT", "3"),
            ("TRAIL_IMPACT_TIMEOUT", "1"),
        ],
    );

    assert!(
        started.elapsed() >= std::time::Duration::from_secs(3),
        "waited {:?} for the language server, not its own 3 s",
        started.elapsed()
    );
    assert!(response["error"]["message"].is_string(), "{response}");
}

/// A language server still reading the workspace, like rust-analyzer right
/// after it starts: it answers every file with an error.
const LOADING_LSP: &str = r#"#!/bin/sh
while IFS= read -r line; do
  case "$line" in
    Content-Length:*) len=$(printf '%s' "${line#Content-Length: }" | tr -d '\r') ;;
    "$(printf '\r')")
      body=$(dd bs=1 count="$len" 2>/dev/null)
      id=$(printf '%s' "$body" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
      if [ -n "$id" ]; then
        case "$body" in
          *'"method":"initialize"'*) out="{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":{\"capabilities\":{}}}" ;;
          *prepareCallHierarchy*) out="{\"jsonrpc\":\"2.0\",\"id\":$id,\"error\":{\"code\":-32603,\"message\":\"file not found\"}}" ;;
          *) out="{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":null}" ;;
        esac
        printf 'Content-Length: %d\r\n\r\n%s' "${#out}" "$out"
      fi ;;
  esac
done
"#;

#[test]
fn a_language_server_still_loading_is_waited_for_and_its_answer_reported() {
    let repo = impact_repo();
    let tools = Repo::new();
    let server = tools.path().join("loading-lsp");
    std::fs::write(&server, LOADING_LSP).unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&server)
        .status()
        .unwrap();

    let started = std::time::Instant::now();
    let response = impact_response(
        &repo,
        true,
        &[
            ("TRAIL_GOPLS", server.to_str().unwrap()),
            ("TRAIL_LSP_TIMEOUT", "2"),
        ],
    );

    assert!(
        started.elapsed() >= std::time::Duration::from_secs(2),
        "gave up after {:?}, before the server's 2 s to load",
        started.elapsed()
    );
    let message = response["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("file not found"), "{response}");
}

#[test]
fn a_missing_language_server_fails_the_impact_and_says_so() {
    let repo = impact_repo();

    let response = impact_response(&repo, true, &[("TRAIL_GOPLS", "/nonexistent/gopls")]);

    let message = response["error"]["message"].as_str().unwrap_or_default();
    assert!(
        message.starts_with("go language server failed: ")
            && message.contains("/nonexistent/gopls"),
        "{response}"
    );
}

#[test]
fn a_changed_file_the_build_leaves_out_does_not_stop_the_language_server() {
    if !has_gopls() {
        return;
    }
    let (repo, _) = branch_with(
        &[
            ("go.mod", "module example.com/m\n\ngo 1.22\n"),
            (
                "run/run.go",
                "package run\n\nfunc Work() int {\n\treturn 1\n}\n\nfunc Main() int {\n\treturn Work()\n}\n",
            ),
        ],
        &[
            (
                "run/run.go",
                "package run\n\nfunc Work() int {\n\treturn 2\n}\n\nfunc Main() int {\n\treturn Work()\n}\n",
            ),
            (
                "run/legacy.go",
                "//go:build ignore\n\npackage run\n\nfunc Legacy() int {\n\treturn 3\n}\n",
            ),
        ],
        &[],
    );

    let result = impact(&repo, &[]);

    let work = result["paths"]
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["steps"] == json!(["go:run.Work"]))
        .unwrap_or_else(|| panic!("no path for Work: {result}"));
    assert_eq!(
        impact_edges(work),
        [edge4("run.Main", "run.Work", "", "lsp")]
    );
}

#[test]
fn calls_through_an_interface_from_outside_the_repository_do_not_join_paths() {
    if !has_gopls() {
        return;
    }
    let (repo, _) = branch_with(
        &[
            ("go.mod", "module example.com/m\n\ngo 1.22\n"),
            (
                "shop/shop.go",
                "package shop\n\nimport \"fmt\"\n\ntype Order struct{ ID string }\n\nfunc (o Order) String() string {\n\treturn o.ID\n}\n\nfunc describe(s fmt.Stringer) string {\n\treturn s.String()\n}\n\nfunc Print() string {\n\treturn describe(Order{})\n}\n",
            ),
        ],
        &[(
            "shop/shop.go",
            "package shop\n\nimport \"fmt\"\n\ntype Order struct{ ID string }\n\nfunc (o Order) String() string {\n\treturn \"order \" + o.ID\n}\n\nfunc describe(s fmt.Stringer) string {\n\treturn \"[\" + s.String() + \"]\"\n}\n\nfunc Print() string {\n\treturn describe(Order{})\n}\n",
        )],
        &[],
    );

    let result = impact(&repo, &[]);

    let steps: Vec<&Value> = result["paths"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| &p["steps"])
        .collect();
    assert_eq!(
        steps,
        [
            &json!(["go:shop.Order.String"]),
            &json!(["go:shop.describe"])
        ],
        "{result}"
    );
    assert!(
        impact_edges(&result["paths"][0]).contains(&edge4(
            "shop.describe",
            "shop.Order.String",
            "fmt.Stringer.String",
            "lsp"
        )),
        "{result}"
    );
}

#[test]
fn a_later_tree_shows_its_own_change_before_it_joins() {
    let (repo, _) = branch_with(
        &[
            ("go.mod", "module example.com/m\n\ngo 1.22\n"),
            (
                "store/store.go",
                "package store\n\nfunc Save() int {\n\treturn 1\n}\n",
            ),
            (
                "svc/svc.go",
                "package svc\n\nimport \"example.com/m/store\"\n\nfunc Create() int {\n\treturn store.Save()\n}\n\nfunc Import() int {\n\treturn Create()\n}\n\nfunc Retry() int {\n\treturn store.Save()\n}\n",
            ),
            (
                "api/api.go",
                "package api\n\nimport \"example.com/m/svc\"\n\nfunc Handle() int {\n\treturn svc.Create()\n}\n",
            ),
            (
                "worker/worker.go",
                "package worker\n\nimport \"example.com/m/svc\"\n\nfunc Run() int {\n\treturn svc.Retry()\n}\n",
            ),
            (
                "cmd/tool/main.go",
                "package main\n\nimport \"example.com/m/svc\"\n\nfunc main() {\n\t_ = svc.Import()\n}\n",
            ),
        ],
        &[
            (
                "store/store.go",
                "package store\n\nfunc Save() int {\n\treturn 2\n}\n",
            ),
            (
                "svc/svc.go",
                "package svc\n\nimport \"example.com/m/store\"\n\nfunc Create() int {\n\treturn store.Save()\n}\n\nfunc Import() int {\n\treturn Create()\n}\n\nfunc Retry() int {\n\treturn store.Save() + 1\n}\n",
            ),
            (
                "api/api.go",
                "package api\n\nimport \"example.com/m/svc\"\n\nfunc Handle() int {\n\treturn svc.Create() + 1\n}\n",
            ),
        ],
        &[],
    );

    let result = impact_by_name(&repo, &[]);

    let path = &result["paths"][0];
    assert_eq!(
        impact_trees(path),
        [
            vec!["api.Handle", "  svc.Create", "    store.Save"],
            vec!["worker.Run", "  svc.Retry", "    store.Save ↑"],
            vec!["cmd/tool.main *", "  svc.Import", "    svc.Create ↑"],
        ],
        "{result}"
    );
    assert_eq!(
        path["steps"],
        json!(["go:api.Handle", "go:store.Save", "go:svc.Retry"]),
        "steps follow the trees top to bottom"
    );
}

#[test]
fn impact_names_rust_functions_by_module_and_short_name() {
    let (repo, _) = branch_with(
        &[
            (
                "Cargo.toml",
                "[package]\nname = \"m\"\nversion = \"0.1.0\"\nedition = \"2021\"\n",
            ),
            (
                "src/lib.rs",
                "pub mod store;\n\npub fn run() -> u32 {\n    store::Store::new().save()\n}\n",
            ),
            (
                "src/store.rs",
                "pub struct Store;\n\nimpl Store {\n    pub fn new() -> Store {\n        Store\n    }\n\n    pub fn save(&self) -> u32 {\n        1\n    }\n}\n",
            ),
        ],
        &[(
            "src/store.rs",
            "pub struct Store;\n\nimpl Store {\n    pub fn new() -> Store {\n        Store\n    }\n\n    pub fn save(&self) -> u32 {\n        2\n    }\n}\n",
        )],
        &[],
    );

    let result = impact_by_name(&repo, &[]);

    let path = &result["paths"][0];
    let named = |id: &str| {
        let n = path["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .find(|n| n["id"] == id)
            .unwrap_or_else(|| panic!("no node {id} in {result}"));
        (n["package"].as_str().unwrap(), n["short"].as_str().unwrap())
    };
    assert_eq!(
        path["steps"],
        json!(["rust:store::Store::save"]),
        "{result}"
    );
    assert_eq!(named("rust:store::Store::save"), ("store", "Store::save"));
}

#[test]
fn an_interface_method_with_no_implementation_in_the_repository_is_named() {
    if !has_gopls() {
        return;
    }
    let file = |n: u32| {
        format!(
            "package flow\n\ntype resetter interface {{\n\tReset()\n}}\n\nfunc Clear(r resetter) int {{\n\tr.Reset()\n\treturn {n}\n}}\n"
        )
    };
    let (repo, _) = branch_with(
        &[
            ("go.mod", "module example.com/m\n\ngo 1.22\n"),
            ("flow/flow.go", &file(1)),
        ],
        &[("flow/flow.go", &file(2))],
        &[],
    );

    let result = impact(&repo, &[]);

    assert_eq!(
        impact_trees(&result["paths"][0]),
        [vec!["flow.Clear", "  flow.resetter.Reset"]],
        "{result}"
    );
    let reset = impact_node(&result["paths"][0], "flow.resetter.Reset");
    assert_eq!(
        (reset["package"].as_str(), reset["short"].as_str()),
        (Some("flow"), Some("resetter.Reset"))
    );
}

#[test]
fn a_changed_type_starts_its_path_at_the_functions_using_it() {
    let (repo, _) = branch_with(
        &[
            ("go.mod", "module example.com/m\n\ngo 1.22\n"),
            (
                "store/store.go",
                "package store\n\ntype Store struct {\n\tn int\n}\n",
            ),
            (
                "store/run.go",
                "package store\n\nfunc Run(s *Store) int {\n\treturn s.n\n}\n",
            ),
            (
                "cmd/tool/main.go",
                "package main\n\nimport \"example.com/m/store\"\n\nfunc main() {\n\t_ = store.Run(nil)\n}\n",
            ),
        ],
        &[(
            "store/store.go",
            "package store\n\ntype Store struct {\n\tn    int\n\tname string\n}\n",
        )],
        &[],
    );

    let result = impact_by_name(&repo, &[]);

    let path = &result["paths"][0];
    assert_eq!(path["steps"], json!(["go:store.Store"]), "{result}");
    assert_eq!(
        impact_trees(path),
        [vec!["cmd/tool.main", "  store.Run", "    store.Store"]],
        "{result}"
    );
    let store = impact_node(path, "store.Store");
    assert_eq!(
        (
            store["package"].as_str(),
            store["short"].as_str(),
            store["status"].as_str()
        ),
        (Some("store"), Some("Store"), Some("modified"))
    );
}

#[test]
fn ignored_files_are_left_out_and_listed() {
    let repo = Repo::new();
    repo.write("keep.go", "package k\n\nfunc A() {}\n");
    repo.write("api/types.pb.go", "package api\n\nfunc P() {}\n");
    repo.write("vendor/dep/dep.go", "package dep\n\nfunc D() {}\n");
    repo.write("docs/go.sum", "a\n");
    repo.write("go.sum", "a\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write("keep.go", "package k\n\nfunc A() { x() }\n");
    repo.write("api/types.pb.go", "package api\n\nfunc P() { x() }\n");
    repo.write("vendor/dep/dep.go", "package dep\n\nfunc D() { x() }\n");
    repo.write("docs/go.sum", "b\n");
    repo.write("go.sum", "b\n");
    repo.commit("feature");

    let responses = serve(&[json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "open",
        "params": {
            "repo": repo.path(),
            "base": "main",
            "head": "feature",
            "ignore": ["*.pb.go", "vendor/", "/go.sum"],
            "ignore_defaults": false,
        },
    })]);
    let result = &responses[0]["result"];
    let kept: Vec<&str> = result["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["path"].as_str().unwrap())
        .collect();
    assert_eq!(kept, ["docs/go.sum", "keep.go"]);
    assert_eq!(
        result["ignored"],
        json!(["api/types.pb.go", "go.sum", "vendor/dep/dep.go"])
    );
    assert!(hunks_of(result, "api/types.pb.go").is_empty());
    assert!(
        result["nodes"]
            .as_array()
            .unwrap()
            .iter()
            .all(|n| n["file"] == "keep.go")
    );
}

#[test]
fn go_and_rust_lockfiles_vendored_and_generated_code_are_ignored_by_default() {
    let repo = Repo::new();
    let files = [
        ("keep.go", "package k\n\nfunc A() {}\n"),
        ("src/target/keep.go", "package target\n\nfunc T() {}\n"),
        ("go.sum", "a\n"),
        ("sub/go.sum", "a\n"),
        ("vendor/dep/dep.go", "package dep\n\nfunc D() {}\n"),
        ("api/x.pb.go", "package api\n\nfunc P() {}\n"),
        ("api/x_gen.go", "package api\n\nfunc G() {}\n"),
        ("zz_generated.deepcopy.go", "package api\n\nfunc Z() {}\n"),
        ("Cargo.lock", "a\n"),
        ("target/debug/out.rs", "fn o() {}\n"),
    ];
    for (path, content) in files {
        repo.write(path, content);
    }
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    for (path, content) in files {
        repo.write(path, &format!("{content}// changed\n"));
    }
    repo.commit("feature");

    let paths_of = |params: Value| -> (Vec<String>, Vec<String>) {
        let mut p = json!({ "repo": repo.path(), "base": "main", "head": "feature" });
        p.as_object_mut()
            .unwrap()
            .extend(params.as_object().unwrap().clone());
        let responses =
            serve(&[json!({ "jsonrpc": "2.0", "id": 1, "method": "open", "params": p })]);
        let list = |key: &str| -> Vec<String> {
            responses[0]["result"][key]
                .as_array()
                .unwrap()
                .iter()
                .map(|f| f.as_str().or(f["path"].as_str()).unwrap().to_string())
                .collect()
        };
        (list("files"), list("ignored"))
    };

    let (kept, ignored) = paths_of(json!({}));
    assert_eq!(kept, ["keep.go", "src/target/keep.go"]);
    assert_eq!(ignored.len(), 8, "{ignored:?}");

    let (kept, ignored) = paths_of(json!({ "ignore_defaults": false }));
    assert_eq!(kept.len(), 10);
    assert!(ignored.is_empty());
}

fn fake_gh_for_reviews(dir: &Path, host: &str) -> PathBuf {
    let script = dir.join("gh");
    let files = r#"["a.go","@@ -1,4 +1,6 @@\n x\n-y\n+y2\n+z\n@@ -20,2 +22,3 @@\n m\n+n"]
["gone.go",""]"#;
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  'api --hostname {host} repos/owner/repo/pulls/7/files --paginate'*) printf '%s\\n' '{files}' ;;\n  'api --hostname {host} --method POST repos/owner/repo/pulls/7/reviews --input -') cat > \"{0}/payload.json\"; echo '{{\"id\":1,\"html_url\":\"https://{host}/owner/repo/pull/7#pullrequestreview-1\"}}' ;;\n  'api --hostname {host} --method POST repos/owner/repo/pulls/7/comments --input -') cat > \"{0}/comment.json\"; echo '{{\"id\":2,\"html_url\":\"https://{host}/owner/repo/pull/7#discussion_r2\"}}' ;;\n  *) echo \"HTTP 401: Bad credentials (unexpected: $*)\" >&2; exit 1 ;;\nesac\n",
            dir.display()
        ),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&script)
        .status()
        .unwrap();
    script
}

#[test]
fn a_review_is_submitted_with_inline_comments_and_the_rest_in_its_body() {
    let tools = Repo::new();
    let gh = fake_gh_for_reviews(tools.path(), "github.com");
    let submit = |event: Value| {
        let responses = serve_with_env(
            &[json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "submit_review",
                "params": {
                    "repo": tools.path(),
                    "url": "https://github.com/owner/repo/pull/7",
                    "number": 7,
                    "commit": "abc123",
                    "event": event,
                    "body": "Looks close.",
                    "comments": [
                        { "path": "a.go", "side": "new", "line": 2, "body": "**nit:** name" },
                        { "path": "a.go", "side": "new", "line": 2, "last": 3, "body": "**question:** why?" },
                        { "path": "a.go", "side": "old", "line": 2, "body": "**blocking:** keep" },
                        { "path": "a.go", "side": "new", "line": 10, "body": "**nit:** far away" },
                        { "path": "a.go", "side": "new", "line": 6, "last": 22, "body": "**nit:** spans hunks" },
                        { "path": "other.go", "side": "new", "line": 1, "last": 2, "body": "**nit:** not in the PR" },
                    ],
                },
            })],
            &[("TRAIL_GH", gh.to_str().unwrap())],
        );
        let payload: Value = serde_json::from_str(
            &std::fs::read_to_string(tools.path().join("payload.json")).unwrap(),
        )
        .unwrap();
        (responses.into_iter().next().unwrap(), payload)
    };

    let (response, payload) = submit(json!("REQUEST_CHANGES"));
    assert_eq!(
        response["result"],
        json!({ "url": "https://github.com/owner/repo/pull/7#pullrequestreview-1", "inline": 3, "in_body": 3, "inline_comments": [0, 1, 2] }),
        "{response}"
    );
    assert_eq!(payload["commit_id"], "abc123");
    assert_eq!(payload["event"], "REQUEST_CHANGES");
    assert_eq!(
        payload["comments"],
        json!([
            { "path": "a.go", "body": "**nit:** name", "line": 2, "side": "RIGHT" },
            { "path": "a.go", "body": "**question:** why?", "line": 3, "side": "RIGHT", "start_line": 2, "start_side": "RIGHT" },
            { "path": "a.go", "body": "**blocking:** keep", "line": 2, "side": "LEFT" },
        ])
    );
    assert_eq!(
        payload["body"],
        "Looks close.\n\nComments on lines outside the diff:\n\n- `a.go` line 10: **nit:** far away\n- `a.go` line 6-22: **nit:** spans hunks\n- `other.go` line 1-2: **nit:** not in the PR"
    );

    let (_, payload) = submit(Value::Null);
    assert!(
        payload.get("event").is_none(),
        "a draft is a pending review: {payload}"
    );
}

#[test]
fn a_comment_written_on_an_earlier_commit_is_submitted_on_its_line_at_the_head() {
    let repo = Repo::new();
    repo.write("a.go", "x\ny\nq\nw\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write("a.go", "x\nT\nq\nw\n");
    repo.commit("first");
    let first = rev(&repo, "HEAD");
    repo.write("a.go", "x\ny2\nz\nT\nq\nw\n");
    repo.commit("second");
    let head = rev(&repo, "HEAD");
    let gh = fake_gh_for_reviews(repo.path(), "github.com");

    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "submit_review",
            "params": {
                "repo": repo.path(),
                "url": "https://github.com/owner/repo/pull/7",
                "number": 7,
                "commit": head,
                "base": "main",
                "event": "COMMENT",
                "body": "",
                "comments": [
                    { "path": "a.go", "side": "new", "line": 2, "text": "T", "body": "**nit:** moved down" },
                    { "path": "a.go", "side": "old", "line": 1, "text": "y", "body": "**nit:** on the base" },
                    { "path": "a.go", "side": "new", "line": 3, "text": "only in the first", "body": "**nit:** gone" },
                ],
            },
        })],
        &[("TRAIL_GH", gh.to_str().unwrap())],
    );

    assert!(responses[0]["result"].is_object(), "{}", responses[0]);
    let payload: Value =
        serde_json::from_str(&std::fs::read_to_string(repo.path().join("payload.json")).unwrap())
            .unwrap();
    assert_eq!(
        payload["comments"],
        json!([
            { "path": "a.go", "body": "**nit:** moved down", "line": 4, "side": "RIGHT" },
            { "path": "a.go", "body": "**nit:** on the base", "line": 2, "side": "LEFT" },
        ]),
        "lines are found again by their text at the pull request's head and base (first was {first})"
    );
    assert!(
        payload["body"]
            .as_str()
            .unwrap()
            .contains("- `a.go` line 3: **nit:** gone"),
        "a line the head no longer has goes to the body: {payload}"
    );
}

#[test]
fn a_comment_is_posted_on_its_own_at_once() {
    let repo = Repo::new();
    repo.write("a.go", "x\ny\nq\nw\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write("a.go", "x\ny2\nz\nT\nq\nw\n");
    repo.commit("change");
    let head = rev(&repo, "HEAD");
    let gh = fake_gh_for_reviews(repo.path(), "github.com");
    let post = |comment: Value| {
        let mut params = json!({
            "repo": repo.path(),
            "url": "https://github.com/owner/repo/pull/7",
            "number": 7,
            "commit": head,
            "base": "main",
        });
        params["comment"] = comment;
        serve_with_env(
            &[json!({ "jsonrpc": "2.0", "id": 1, "method": "post_comment", "params": params })],
            &[("TRAIL_GH", gh.to_str().unwrap())],
        )
        .into_iter()
        .next()
        .unwrap()
    };

    let response = post(
        json!({ "path": "a.go", "side": "new", "line": 2, "text": "T", "body": "**nit:** now" }),
    );

    assert_eq!(
        response["result"]["url"], "https://github.com/owner/repo/pull/7#discussion_r2",
        "{response}"
    );
    let payload: Value =
        serde_json::from_str(&std::fs::read_to_string(repo.path().join("comment.json")).unwrap())
            .unwrap();
    assert_eq!(
        payload,
        json!({ "commit_id": head, "path": "a.go", "body": "**nit:** now", "line": 4, "side": "RIGHT" }),
        "found again by its text at the head"
    );

    let outside =
        post(json!({ "path": "a.go", "side": "new", "line": 30, "body": "**nit:** far" }));
    assert!(
        outside["error"]["message"]
            .as_str()
            .is_some_and(|m| m.contains("not in the pull request's diff")),
        "a line GitHub's diff lacks can only go in a review: {outside}"
    );
}

#[test]
fn commits_lists_a_range_s_commits_oldest_first() {
    let repo = Repo::new();
    repo.write("a.go", "a\n");
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    for (n, subject) in ["Add hashing", "Rename login arg", "Fix typo"]
        .iter()
        .enumerate()
    {
        repo.write("a.go", &format!("a{n}\n"));
        repo.commit(subject);
    }
    repo.git(&["checkout", "-q", "main"]);
    repo.write("b.go", "b\n");
    repo.commit("on main since");

    let responses = serve(&[json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": "commits",
        "params": { "repo": repo.path(), "base": "main", "head": "feature" },
    })]);

    let commits = responses[0]["result"]
        .as_array()
        .unwrap_or_else(|| panic!("{}", responses[0]));
    let subjects: Vec<&str> = commits
        .iter()
        .map(|c| c["subject"].as_str().unwrap())
        .collect();
    assert_eq!(subjects, ["Add hashing", "Rename login arg", "Fix typo"]);
    let last = &commits[2];
    assert_eq!(last["id"].as_str().unwrap(), rev(&repo, "feature"));
    assert_eq!(last["short"].as_str().unwrap().len(), 7);
    assert!(
        last["author"].is_string() && last["date"].is_string(),
        "{last}"
    );
}

#[test]
fn a_function_s_calls_are_laid_out_in_the_order_its_body_makes_them() {
    let repo = Repo::new();
    let base = "package a\n\nfunc Top() {\n\tb()\n\ta()\n}\n\nfunc a() { c() }\n\nfunc b() {}\n\nfunc c() {}\n";
    repo.write("go.mod", "module ex\n\ngo 1.22\n");
    repo.write("a.go", base);
    repo.commit("base");
    repo.git(&["checkout", "-q", "-b", "feature"]);
    repo.write(
        "a.go",
        "package a\n\nfunc Top() {\n\tb()\n\ta()\n\t_ = 0\n}\n\nfunc a() { c(); _ = 1 }\n\nfunc b() { _ = 2 }\n\nfunc c() { _ = 3 }\n",
    );
    repo.commit("feature");

    let result = impact_by_name(&repo, &[]);

    let path = &result["paths"][0];
    assert_eq!(
        impact_trees(path),
        [["a.Top", "  a.b", "  a.a", "    a.c"]],
        "b is called first, though a has more changes below it: {result}"
    );
    let names: Vec<&str> = path["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|id| {
            path["nodes"]
                .as_array()
                .unwrap()
                .iter()
                .find(|n| &n["id"] == id)
                .unwrap()["name"]
                .as_str()
                .unwrap()
        })
        .collect();
    assert_eq!(
        names,
        ["a.Top", "a.b", "a.a", "a.c"],
        "steps follow the same order"
    );
}

#[test]
fn a_review_on_github_enterprise_goes_to_that_host() {
    let tools = Repo::new();
    let gh = fake_gh_for_reviews(tools.path(), "ghe.example.com");
    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "submit_review",
            "params": {
                "repo": tools.path(),
                "url": "https://ghe.example.com/owner/repo/pull/7",
                "number": 7,
                "commit": "abc123",
                "body": "From the company host.",
            },
        })],
        &[("TRAIL_GH", gh.to_str().unwrap())],
    );
    assert_eq!(
        responses[0]["result"]["url"],
        "https://ghe.example.com/owner/repo/pull/7#pullrequestreview-1",
        "gh api defaults to github.com, so the pull request's own host is passed: {}",
        responses[0]
    );
}

#[test]
fn review_threads_are_read_page_by_page_from_the_pull_request_s_host() {
    let tools = Repo::new();
    let page = |cursor: &str, more: bool, nodes: Value| {
        json!({ "data": { "repository": { "pullRequest": { "reviewThreads": {
            "pageInfo": { "hasNextPage": more, "endCursor": cursor },
            "nodes": nodes,
        } } } } })
        .to_string()
    };
    let first = page(
        "c1",
        true,
        json!([{
            "id": "T1", "isResolved": false, "isOutdated": false, "path": "a.go",
            "line": 12, "startLine": 10, "originalLine": 12, "diffSide": "RIGHT",
            "comments": { "nodes": [
                { "author": { "login": "alice" }, "body": "why?", "createdAt": "2026-11-17T10:00:00Z",
                  "url": "https://ghe.example.com/owner/repo/pull/7#discussion_r1", "diffHunk": "@@ -1,2 +1,3 @@\n a\n+b" },
                { "author": null, "body": "because", "createdAt": "2026-11-17T11:00:00Z",
                  "url": "https://ghe.example.com/owner/repo/pull/7#discussion_r2", "diffHunk": "@@" },
            ] },
        }]),
    );
    let second = page(
        "c2",
        false,
        json!([{
            "id": "T2", "isResolved": true, "isOutdated": true, "path": "b.go",
            "line": null, "startLine": null, "originalLine": 4, "diffSide": "LEFT",
            "comments": { "nodes": [
                { "author": { "login": "bob" }, "body": "old", "createdAt": "2026-11-16T09:00:00Z",
                  "url": "https://ghe.example.com/owner/repo/pull/7#discussion_r3", "diffHunk": "@@ -4 +4 @@\n-x" },
            ] },
        }]),
    );
    std::fs::write(tools.path().join("page1.json"), first).unwrap();
    std::fs::write(tools.path().join("page2.json"), second).unwrap();
    let script = tools.path().join("gh");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  'api graphql --hostname ghe.example.com -F owner=owner -F name=repo -F number=7 -f after=c1 -f query='*) cat \"{dir}/page2.json\" ;;\n  'api graphql --hostname ghe.example.com -F owner=owner -F name=repo -F number=7 -f query='*) cat \"{dir}/page1.json\" ;;\n  *) echo \"HTTP 401: Bad credentials (unexpected: $*)\" >&2; exit 1 ;;\nesac\n",
            dir = tools.path().display()
        ),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&script)
        .status()
        .unwrap();

    let responses = serve_with_env(
        &[json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "review_threads",
            "params": { "repo": tools.path(), "url": "https://ghe.example.com/owner/repo/pull/7", "number": 7 },
        })],
        &[("TRAIL_GH", script.to_str().unwrap())],
    );
    assert_eq!(
        responses[0]["result"],
        json!([
            {
                "id": "T1", "path": "a.go", "side": "new", "line": 12, "start_line": 10, "original_line": 12,
                "resolved": false, "outdated": false, "diff_hunk": "@@ -1,2 +1,3 @@\n a\n+b",
                "comments": [
                    { "author": "alice", "body": "why?", "created_at": "2026-11-17T10:00:00Z",
                      "url": "https://ghe.example.com/owner/repo/pull/7#discussion_r1" },
                    { "author": "ghost", "body": "because", "created_at": "2026-11-17T11:00:00Z",
                      "url": "https://ghe.example.com/owner/repo/pull/7#discussion_r2" },
                ],
            },
            {
                "id": "T2", "path": "b.go", "side": "old", "line": null, "start_line": null, "original_line": 4,
                "resolved": true, "outdated": true, "diff_hunk": "@@ -4 +4 @@\n-x",
                "comments": [
                    { "author": "bob", "body": "old", "created_at": "2026-11-16T09:00:00Z",
                      "url": "https://ghe.example.com/owner/repo/pull/7#discussion_r3" },
                ],
            },
        ]),
        "{}",
        responses[0]
    );
}

#[test]
fn a_thread_gets_a_reply_and_is_resolved_or_reopened_on_the_pull_request_s_host() {
    let tools = Repo::new();
    let script = tools.path().join("gh");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"{dir}/calls\"\ncase \"$*\" in\n  'api graphql --hostname ghe.example.com -f threadId=T1 -f body='*'-f query=mutation'*addPullRequestReviewThreadReply*) echo '{{}}' ;;\n  'api graphql --hostname ghe.example.com -f threadId=T1 -f query=mutation'*'{{ resolveReviewThread('*) echo '{{}}' ;;\n  *) echo \"GraphQL: unexpected ($*)\" >&2; exit 1 ;;\nesac\n",
            dir = tools.path().display()
        ),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&script)
        .status()
        .unwrap();
    let update = |body: &str, state: Value| {
        let _ = std::fs::remove_file(tools.path().join("calls"));
        let responses = serve_with_env(
            &[json!({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "update_thread",
                "params": {
                    "repo": tools.path(),
                    "url": "https://ghe.example.com/owner/repo/pull/7",
                    "number": 7,
                    "thread": "T1",
                    "body": body,
                    "state": state,
                },
            })],
            &[("TRAIL_GH", script.to_str().unwrap())],
        );
        let calls = std::fs::read_to_string(tools.path().join("calls")).unwrap_or_default();
        let mutations: Vec<&str> = [
            "addPullRequestReviewThreadReply",
            "unresolveReviewThread",
            "resolveReviewThread",
        ]
        .into_iter()
        .filter(|m| {
            calls
                .lines()
                .any(|l| l.contains(&format!("{{ {m}(")) || l.contains(&format!(" {m}(")))
        })
        .collect();
        (responses.into_iter().next().unwrap(), mutations, calls)
    };

    let (response, mutations, calls) = update("Fixed in the next push.\nThanks!", json!("resolve"));
    assert_eq!(response["result"], json!({}), "{response}");
    assert_eq!(
        mutations,
        ["addPullRequestReviewThreadReply", "resolveReviewThread"]
    );
    assert!(
        calls.contains("-f body=Fixed in the next push.\nThanks!"),
        "{calls}"
    );

    let (response, mutations, _) = update("  ", json!("resolve"));
    assert_eq!(response["result"], json!({}), "{response}");
    assert_eq!(
        mutations,
        ["resolveReviewThread"],
        "an empty reply posts nothing"
    );

    let (response, _, _) = update("", json!("reopen"));
    assert!(
        response["error"]["message"]
            .as_str()
            .unwrap()
            .contains("GraphQL: unexpected"),
        "GitHub's error comes back: {response}"
    );
}

#[test]
fn open_pull_requests_are_listed_with_those_asking_for_your_review_first() {
    let tools = Repo::new();
    let script = tools.path().join("gh");
    let all = r#"[{"number":3,"title":"Fix docs","author":{"login":"bob"},"headRefName":"docs","isDraft":false},{"number":7,"title":"Add hashing","author":{"login":"alice"},"headRefName":"hashing","isDraft":true},{"number":9,"title":"Old","author":null,"headRefName":"old","isDraft":false}]"#;
    let mine = r#"[{"number":7,"title":"Add hashing","author":{"login":"alice"},"headRefName":"hashing","isDraft":true}]"#;
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  'pr list --state open --limit 100 --json number,title,author,headRefName,isDraft --search review-requested:@me') echo '{mine}' ;;\n  'pr list --state open --limit 100 --json number,title,author,headRefName,isDraft') echo '{all}' ;;\n  *) echo \"unexpected: $*\" >&2; exit 1 ;;\nesac\n"
        ),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&script)
        .status()
        .unwrap();
    let responses = serve_with_env(
        &[
            json!({ "jsonrpc": "2.0", "id": 1, "method": "pull_requests", "params": { "repo": tools.path() } }),
        ],
        &[("TRAIL_GH", script.to_str().unwrap())],
    );
    assert_eq!(
        responses[0]["result"],
        json!([
            { "number": 7, "title": "Add hashing", "author": "alice", "head_ref_name": "hashing", "is_draft": true, "review_requested": true },
            { "number": 3, "title": "Fix docs", "author": "bob", "head_ref_name": "docs", "is_draft": false, "review_requested": false },
            { "number": 9, "title": "Old", "author": "ghost", "head_ref_name": "old", "is_draft": false, "review_requested": false },
        ]),
        "{}",
        responses[0]
    );
}

#[test]
fn the_trail_command_starts_neovim_with_trail_s_own_config() {
    let tools = Repo::new();
    let script = tools.path().join("nvim");
    let out = tools.path().join("calls");
    std::fs::write(
        &script,
        format!(
            "#!/bin/sh\n{{ printf 'args:'; for a in \"$@\"; do printf ' [%s]' \"$a\"; done; echo; echo \"appname:$NVIM_APPNAME\"; echo \"target:$TRAIL_ARGS\"; echo \"user:$TRAIL_USER_APPNAME\"; }} > \"{}\"\n",
            out.display()
        ),
    )
    .unwrap();
    Command::new("chmod")
        .arg("+x")
        .arg(&script)
        .status()
        .unwrap();
    let run = |args: &[&str], appname: Option<&str>| {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_trail"));
        cmd.args(args)
            .env("TRAIL_NVIM", &script)
            .env("TRAIL_APP_INIT", "/somewhere/app/init.lua")
            .env_remove("NVIM_APPNAME")
            .env_remove("TRAIL_ARGS");
        if let Some(name) = appname {
            cmd.env("NVIM_APPNAME", name);
        }
        assert!(cmd.status().unwrap().success());
        std::fs::read_to_string(&out).unwrap()
    };

    assert_eq!(
        run(&["#1241"], None),
        "args: [-u] [/somewhere/app/init.lua]\nappname:trail\ntarget:#1241\nuser:\n",
        "the app runs Neovim with trail's startup file, under its own NVIM_APPNAME"
    );
    assert_eq!(
        run(&[], Some("work")),
        "args: [-u] [/somewhere/app/init.lua]\nappname:trail\ntarget:\nuser:work\n",
        "with no target it opens the picker, and remembers the user's own NVIM_APPNAME for gd"
    );
    assert_eq!(
        run(&["--my-config", "main..feature"], None),
        "args: [+Trail main..feature]\nappname:\ntarget:\nuser:\n",
        "--my-config runs the user's Neovim with :Trail"
    );
}
