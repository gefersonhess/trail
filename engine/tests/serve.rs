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

fn edges(result: &Value) -> Vec<(String, String, String)> {
    let mut edges: Vec<_> = result["edges"]
        .as_array()
        .unwrap()
        .iter()
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
    assert_eq!(changes(&result, "new_changes", 8), Some(json!([])));
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
    assert_eq!(added["new_changes"], json!([{ "line": 1, "spans": [] }]));
    assert_eq!(deleted["rows"], json!([[1, null], [2, null], [3, null]]));
    assert_eq!(deleted["old_changes"].as_array().unwrap().len(), 3);
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

/// A fake `gh` that answers `pr view` for pull request 7 of the bare
/// repository at `remote`, whose head is `head`.
fn fake_gh(dir: &Path, remote: &Path, head: &str) -> PathBuf {
    let script = dir.join("gh");
    let json = format!(
        r#"{{"baseRefName":"main","headRefOid":"{head}","title":"Add hashing","url":"file://{}/pull/7"}}"#,
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
