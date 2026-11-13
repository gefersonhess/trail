use std::collections::HashMap;
use std::path::Path;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{Value, json};

use crate::diff::{self, File, Hunk, Range, Status};
use crate::difftastic::{self, Outcome};
use crate::git;
use crate::lsp;
use crate::paths;
use crate::rpc::log;
use crate::symbols::{self, Call, Import, Kind, Symbol, Via};
use crate::worktree;

#[derive(Serialize)]
pub struct Review {
    pub base_commit: String,
    pub head_commit: String,
    pub files: Vec<File>,
    pub hunks: Vec<Hunk>,
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
    pub paths: Vec<paths::Path>,
    pub tests: Vec<paths::TestFile>,
    pub uncovered: Vec<String>,
    pub unassigned: Vec<String>,
}

#[derive(Serialize)]
pub struct Node {
    pub id: String,
    kind: Kind,
    pub status: NodeStatus,
    pub file: String,
    old: Option<Range>,
    new: Option<Range>,
    pub hunks: Vec<String>,
    pub is_test: bool,
    #[serde(skip)]
    old_calls: Vec<Call>,
    #[serde(skip)]
    new_calls: Vec<Call>,
    #[serde(skip)]
    new_name_at: Option<(u32, usize)>,
    #[serde(skip)]
    old_refs: Vec<String>,
    #[serde(skip)]
    new_refs: Vec<String>,
    #[serde(skip)]
    old_imports: Vec<Import>,
    #[serde(skip)]
    new_imports: Vec<Import>,
}

#[derive(Serialize)]
pub struct Edge {
    pub from: String,
    pub to: String,
    pub status: EdgeStatus,
    /// `call`, or `use` for a function mentioning a type or constant.
    pub kind: &'static str,
    source: &'static str,
}

#[derive(Serialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum EdgeStatus {
    Added,
    Removed,
    Unchanged,
}

#[derive(Serialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum NodeStatus {
    Added,
    Modified,
    Removed,
    /// Unchanged code shown because it uses a changed type or constant.
    Context,
}

/// Reviews `head` against its merge base with `base`, like `git diff base...head`,
/// so changes that landed on `base` after the branch point are not shown.
pub fn open(repo: &Path, base: &str, head: &str, lsp: bool) -> Result<Review, String> {
    let head_commit = git::commit(repo, head)?;
    let base_tip = git::commit(repo, base)?;
    let base_commit = git::run(repo, &["merge-base", &base_tip, &head_commit])?
        .trim()
        .to_string();
    let mut diff = diff::compute(repo, &base_commit, &head_commit, &[])?;
    let mut nodes = Vec::new();
    let mut formatting_only: Vec<String> = Vec::new();
    for file in &diff.files {
        let Some(language) = file.language.filter(|_| !file.binary) else {
            continue;
        };
        let old_path = file.old_path.as_deref().unwrap_or(&file.path);
        let read = |commit: &str, path: &str, present: bool| -> Result<String, String> {
            if present {
                git::show(repo, commit, path)
            } else {
                Ok(String::new())
            }
        };
        let old_src = read(&base_commit, old_path, file.status != Status::Added)?;
        let new_src = read(&head_commit, &file.path, file.status != Status::Deleted)?;
        let mut hunks: Vec<&Hunk> = diff.hunks.iter().filter(|h| h.file == file.path).collect();
        if matches!(file.status, Status::Modified | Status::Renamed) {
            let (real, noise) = split_by_difftastic(&file.path, &old_src, &new_src, hunks);
            formatting_only.extend(noise.iter().map(|h| h.id.clone()));
            hunks = real;
        }
        let old = symbols::extract(language, old_path, &old_src);
        let new = symbols::extract(language, &file.path, &new_src);
        let imports = |src: &str| {
            if language == "rust" {
                symbols::rust_imports(src)
            } else {
                Vec::new()
            }
        };
        let files_imports = (imports(&old_src), imports(&new_src));
        nodes.extend(changed_nodes(
            file,
            language,
            &old,
            &new,
            &hunks,
            &files_imports,
        ));
    }
    nodes.extend(context_nodes(repo, &head_commit, &nodes)?);
    diff.hunks.retain(|h| !formatting_only.contains(&h.id));
    let hunks = &diff.hunks;
    diff.files.retain(|f| {
        f.status != Status::Modified || f.binary || hunks.iter().any(|h| h.file == f.path)
    });
    let mut edges = edges(&nodes);
    edges.extend(use_edges(&nodes));
    if lsp {
        match lsp_edges(repo, &head_commit, &nodes, &edges) {
            Ok(confirmed) => edges = confirmed,
            Err(e) => log(&format!("keeping name-matched calls: {e}")),
        }
    }
    let layout = paths::layout(&diff.files, &diff.hunks, &nodes, &edges);
    Ok(Review {
        base_commit,
        head_commit,
        files: diff.files,
        hunks: diff.hunks,
        edges,
        nodes,
        paths: layout.paths,
        tests: layout.tests,
        uncovered: layout.uncovered,
        unassigned: layout.unassigned,
    })
}

/// Splits a file's hunks into those with a change difftastic sees and those
/// that only reformat code. Without difftastic every hunk counts as real.
fn split_by_difftastic<'a>(
    path: &str,
    old: &str,
    new: &str,
    hunks: Vec<&'a Hunk>,
) -> (Vec<&'a Hunk>, Vec<&'a Hunk>) {
    match difftastic::diff(path, old, new) {
        None => (hunks, Vec::new()),
        Some(Outcome::Unchanged) => (Vec::new(), hunks),
        Some(Outcome::Changed(s)) => hunks.into_iter().partition(|h| {
            let touches = |r: Range, lines: &std::collections::BTreeMap<u32, _>| {
                r.len > 0 && lines.range(r.start..r.start + r.len).next().is_some()
            };
            touches(h.old, &s.old) || touches(h.new, &s.new)
        }),
    }
}

fn changed_nodes(
    file: &File,
    language: &str,
    old: &[Symbol],
    new: &[Symbol],
    hunks: &[&Hunk],
    imports: &(Vec<Import>, Vec<Import>),
) -> Vec<Node> {
    let old_by_id: HashMap<String, &Symbol> = with_ids(old).collect();
    let new_ids: Vec<(String, &Symbol)> = with_ids(new).collect();
    let mut nodes = Vec::new();
    let mut matched = Vec::new();
    let span = |s: &Symbol| Range {
        start: s.start,
        len: s.end - s.start + 1,
    };
    let node =
        |name: &str, kind, status, old: Option<&Symbol>, new: Option<&Symbol>, hunks: &[&Hunk]| {
            let id = format!("{language}:{name}");
            Node {
                is_test: file.is_test || name.split("::").any(|s| s == "tests"),
                id,
                kind,
                status,
                file: file.path.clone(),
                old: old.map(span),
                new: new.map(span),
                hunks: hunks.iter().map(|h| h.id.clone()).collect(),
                old_calls: old.map_or_else(Vec::new, |s| s.calls.clone()),
                new_calls: new.map_or_else(Vec::new, |s| s.calls.clone()),
                new_name_at: new.map(|s| s.name_at),
                old_refs: old.map_or_else(Vec::new, |s| s.refs.clone()),
                new_refs: new.map_or_else(Vec::new, |s| s.refs.clone()),
                old_imports: imports.0.clone(),
                new_imports: imports.1.clone(),
            }
        };

    for (id, n) in &new_ids {
        let o = old_by_id.get(id).copied();
        if o.is_some() {
            matched.push(id.as_str());
        }
        let touching: Vec<&Hunk> = hunks
            .iter()
            .copied()
            .filter(|h| overlaps(h.new, n) || o.is_some_and(|o| overlaps(h.old, o)))
            .collect();
        let status = match o {
            None => NodeStatus::Added,
            Some(_) if touching.is_empty() => continue,
            Some(_) => NodeStatus::Modified,
        };
        nodes.push(node(id, n.kind, status, o, Some(n), &touching));
    }
    for (id, o) in with_ids(old) {
        if matched.contains(&id.as_str()) {
            continue;
        }
        let touching: Vec<&Hunk> = hunks
            .iter()
            .copied()
            .filter(|h| overlaps(h.old, o))
            .collect();
        nodes.push(node(
            &id,
            o.kind,
            NodeStatus::Removed,
            Some(o),
            None,
            &touching,
        ));
    }
    nodes
}

/// Names can repeat in one file (Go allows several `init` functions), so later
/// occurrences get a `#n` suffix.
fn with_ids(symbols: &[Symbol]) -> impl Iterator<Item = (String, &Symbol)> {
    let mut seen: HashMap<&str, u32> = HashMap::new();
    symbols.iter().map(move |s| {
        let n = seen.entry(&s.name).or_insert(0);
        *n += 1;
        let id = if *n == 1 {
            s.name.clone()
        } else {
            format!("{}#{n}", s.name)
        };
        (id, s)
    })
}

fn overlaps(range: Range, symbol: &Symbol) -> bool {
    range.len > 0 && range.start <= symbol.end && range.start + range.len > symbol.start
}

/// Matches each changed node's calls, on each side, to changed nodes by name.
/// Calls only on the new side are added edges, only on the old side removed.
fn edges(nodes: &[Node]) -> Vec<Edge> {
    let old = side_edges(
        nodes,
        |n| n.status != NodeStatus::Added,
        |n| (&n.old_calls, &n.old_imports),
    );
    let new = side_edges(
        nodes,
        |n| n.status != NodeStatus::Removed,
        |n| (&n.new_calls, &n.new_imports),
    );
    let edge = |(from, to): &(&str, &str), status| Edge {
        from: from.to_string(),
        to: to.to_string(),
        status,
        kind: "call",
        source: "name_match",
    };
    let mut edges: Vec<Edge> = new
        .iter()
        .map(|e| {
            edge(
                e,
                if old.contains(e) {
                    EdgeStatus::Unchanged
                } else {
                    EdgeStatus::Added
                },
            )
        })
        .collect();
    edges.extend(
        old.iter()
            .filter(|e| !new.contains(e))
            .map(|e| edge(e, EdgeStatus::Removed)),
    );
    edges
}

fn side_edges(
    nodes: &[Node],
    present: impl Fn(&Node) -> bool + Copy,
    calls: impl Fn(&Node) -> (&[Call], &[Import]),
) -> Vec<(&str, &str)> {
    let mut out = Vec::new();
    for caller in nodes.iter().filter(|n| present(n)) {
        let (caller_calls, imports) = calls(caller);
        for call in caller_calls {
            for target in targets(nodes, present, caller, call, imports) {
                let edge = (caller.id.as_str(), target.id.as_str());
                if !out.contains(&edge) {
                    out.push(edge);
                }
            }
        }
    }
    out
}

fn targets<'a, 'b>(
    nodes: &'a [Node],
    present: impl Fn(&Node) -> bool,
    caller: &'b Node,
    call: &'b Call,
    imports: &[Import],
) -> Vec<&'a Node> {
    let (language, caller_parent, _) = parts(&caller.id);
    let named: Vec<&Node> = nodes
        .iter()
        .filter(|n| present(n) && n.id != caller.id && (caller.is_test || !n.is_test))
        .filter(|n| {
            let (lang, _, name) = parts(&n.id);
            lang == language && name == call.name
        })
        .collect();
    // A qualifier written in code (`auth.`) names a Go package by the last
    // part of its folder; a bare call stays in the caller's exact package.
    let with_parent = |parent: &str, kind: Option<Kind>| -> Vec<&'a Node> {
        named
            .iter()
            .copied()
            .filter(|n| {
                let p = parts(&n.id).1;
                (p == parent || p.rsplit('/').next() == Some(parent))
                    && kind.is_none_or(|k| n.kind == k)
            })
            .collect()
    };
    let in_caller_package = |kind: Kind| -> Vec<&'a Node> {
        named
            .iter()
            .copied()
            .filter(|n| parts(&n.id).1 == caller_parent && n.kind == kind)
            .collect()
    };
    let of_kind =
        |kind| -> Vec<&'a Node> { named.iter().copied().filter(|n| n.kind == kind).collect() };
    let first_nonempty = |a: Vec<&'a Node>, b: Vec<&'a Node>| if a.is_empty() { b } else { a };
    let resolve = |q: &'b str| -> &'b str {
        if q == "Self" || q == "self" {
            caller_parent
        } else {
            q
        }
    };

    match &call.via {
        Via::Plain if language == "go" => in_caller_package(Kind::Function),
        Via::Plain => {
            let local = in_caller_package(Kind::Function);
            if !local.is_empty() {
                return local;
            }
            // Another module's function is reachable by a bare name only
            // through `use`; a glob import leaves it uncertain.
            let imported: Vec<&'a Node> = nodes
                .iter()
                .filter(|n| {
                    present(n)
                        && n.id != caller.id
                        && (caller.is_test || !n.is_test)
                        && n.kind == Kind::Function
                })
                .filter(|n| {
                    let (lang, parent, name) = parts(&n.id);
                    lang == language
                        && imports.iter().any(|i| {
                            !i.glob
                                && i.local == call.name
                                && i.target == name
                                && i.module.as_deref().is_none_or(|m| m == parent)
                        })
                })
                .collect();
            if !imported.is_empty() || !imports.iter().any(|i| i.glob) {
                return imported;
            }
            of_kind(Kind::Function)
        }
        Via::Path(q) => with_parent(resolve(q), None),
        Via::Receiver(Some(q)) => {
            let q = resolve(q);
            let package_function = if language == "go" {
                with_parent(q, Some(Kind::Function))
            } else {
                Vec::new()
            };
            first_nonempty(
                package_function,
                first_nonempty(with_parent(q, Some(Kind::Method)), of_kind(Kind::Method)),
            )
        }
        Via::Receiver(None) => of_kind(Kind::Method),
    }
}

/// Splits `go:auth.Store.Save#2` into language, parent (`Store`) and name
/// (`Save`). `#n` and `@file` suffixes are not part of the name.
fn parts(id: &str) -> (&str, &str, &str) {
    let (language, path) = id.split_once(':').unwrap_or(("", id));
    let path = path.split(['#', '@']).next().unwrap_or(path);
    let mut segments = path.rsplit(if language == "rust" { "::" } else { "." });
    let name = segments.next().unwrap_or("");
    (language, segments.next().unwrap_or(""), name)
}

/// Replaces the head side's name-matched calls with the language server's call
/// hierarchy, run in a checkout of `head_commit`. Removed calls stay
/// name-matched, since the old code has no language server.
fn lsp_edges(
    repo: &Path,
    head_commit: &str,
    nodes: &[Node],
    edges: &[Edge],
) -> Result<Vec<Edge>, String> {
    let live: Vec<&Node> = nodes
        .iter()
        .filter(|n| {
            n.status != NodeStatus::Removed
                && n.new_name_at.is_some()
                && matches!(n.kind, Kind::Function | Kind::Method)
        })
        .collect();
    let mut languages: Vec<&str> = live.iter().map(|n| parts(&n.id).0).collect();
    languages.sort_unstable();
    languages.dedup();
    if languages.is_empty() {
        return Ok(edges.iter().map(Edge::copy).collect());
    }
    let root = worktree::checkout(repo, head_commit)?.path;
    let timeout = Duration::from_secs(
        std::env::var("TRAIL_LSP_TIMEOUT")
            .ok()
            .and_then(|t| t.parse().ok())
            .unwrap_or(60),
    );
    let mut head_pairs: Vec<(String, String)> = Vec::new();
    for language in languages {
        lsp::with_client(language, &root, head_commit, |client| {
            let deadline = Instant::now() + timeout;
            let mut warm = false;
            for node in live.iter().filter(|n| parts(&n.id).0 == language) {
                let (line, character) = node.new_name_at.expect("filtered");
                let params = json!({
                    "textDocument": { "uri": lsp::uri(&root.join(&node.file)) },
                    "position": { "line": line, "character": character },
                });
                let items = loop {
                    let left = deadline.saturating_duration_since(Instant::now());
                    let r = client.request(
                        "textDocument/prepareCallHierarchy",
                        params.clone(),
                        left,
                    )?;
                    if r.as_array().is_some_and(|a| !a.is_empty()) {
                        warm = true;
                        break r;
                    }
                    if warm || Instant::now() >= deadline {
                        break Value::Null;
                    }
                    std::thread::sleep(Duration::from_millis(300));
                };
                for item in items.as_array().into_iter().flatten() {
                    let left = deadline.saturating_duration_since(Instant::now());
                    let calls = client.request(
                        "callHierarchy/outgoingCalls",
                        json!({ "item": item }),
                        left,
                    )?;
                    for call in calls.as_array().into_iter().flatten() {
                        let to = &call["to"];
                        let Some(path) = to["uri"].as_str().and_then(lsp::path_of) else {
                            continue;
                        };
                        let Ok(rel) = path.strip_prefix(&root) else {
                            continue;
                        };
                        let line = to["selectionRange"]["start"]["line"]
                            .as_u64()
                            .unwrap_or(u64::MAX) as u32
                            + 1;
                        let target = live.iter().find(|n| {
                            n.file.as_str() == rel.to_string_lossy()
                                && n.new
                                    .is_some_and(|r| line >= r.start && line < r.start + r.len)
                        });
                        if let Some(target) = target.filter(|t| t.id != node.id) {
                            let pair = (node.id.clone(), target.id.clone());
                            if !head_pairs.contains(&pair) {
                                head_pairs.push(pair);
                            }
                        }
                    }
                }
            }
            if !warm {
                return Err(format!("{language} language server gave no call hierarchy"));
            }
            Ok(())
        })?;
    }
    let old_side = |from: &str, to: &str| {
        edges
            .iter()
            .any(|e| e.from == from && e.to == to && e.status != EdgeStatus::Added)
    };
    let mut confirmed: Vec<Edge> = head_pairs
        .iter()
        .map(|(from, to)| Edge {
            status: if old_side(from, to) {
                EdgeStatus::Unchanged
            } else {
                EdgeStatus::Added
            },
            from: from.clone(),
            to: to.clone(),
            kind: "call",
            source: "lsp",
        })
        .collect();
    confirmed.extend(
        edges
            .iter()
            .filter(|e| {
                e.kind == "use"
                    || (e.status == EdgeStatus::Removed
                        && !head_pairs.iter().any(|(f, t)| *f == e.from && *t == e.to))
            })
            .map(Edge::copy),
    );
    Ok(confirmed)
}

impl Edge {
    fn copy(&self) -> Edge {
        Edge {
            from: self.from.clone(),
            to: self.to.clone(),
            status: self.status,
            kind: self.kind,
            source: self.source,
        }
    }
}

/// Links functions to the changed types and constants they mention, on each
/// side, by name: the same file first, then the same directory, then anywhere.
fn use_edges(nodes: &[Node]) -> Vec<Edge> {
    let side = |present: &dyn Fn(&Node) -> bool, refs: &dyn Fn(&Node) -> &[String]| {
        let mut pairs: Vec<(&str, &str)> = Vec::new();
        for user in nodes
            .iter()
            .filter(|n| present(n) && matches!(n.kind, Kind::Function | Kind::Method))
        {
            let (language, _, _) = parts(&user.id);
            for name in refs(user) {
                let named: Vec<&Node> = nodes
                    .iter()
                    .filter(|n| {
                        present(n) && matches!(n.kind, Kind::Type | Kind::Const) && n.id != user.id
                    })
                    .filter(|n| {
                        let (lang, _, short) = parts(&n.id);
                        lang == language && short == name
                    })
                    .collect();
                let dir = |f: &str| f.rsplit_once('/').map_or("", |(d, _)| d).to_string();
                let same_file: Vec<&Node> = named
                    .iter()
                    .copied()
                    .filter(|n| n.file == user.file)
                    .collect();
                let same_dir: Vec<&Node> = named
                    .iter()
                    .copied()
                    .filter(|n| dir(&n.file) == dir(&user.file))
                    .collect();
                let targets = if !same_file.is_empty() {
                    same_file
                } else if !same_dir.is_empty() {
                    same_dir
                } else {
                    named
                };
                for t in targets {
                    let pair = (user.id.as_str(), t.id.as_str());
                    if !pairs.contains(&pair) {
                        pairs.push(pair);
                    }
                }
            }
        }
        pairs
    };
    let old = side(&|n| n.status != NodeStatus::Added, &|n| &n.old_refs);
    let new = side(&|n| n.status != NodeStatus::Removed, &|n| &n.new_refs);
    let edge = |(from, to): &(&str, &str), status| Edge {
        from: from.to_string(),
        to: to.to_string(),
        status,
        kind: "use",
        source: "name_match",
    };
    let mut out: Vec<Edge> = new
        .iter()
        .map(|e| {
            edge(
                e,
                if old.contains(e) {
                    EdgeStatus::Unchanged
                } else {
                    EdgeStatus::Added
                },
            )
        })
        .collect();
    out.extend(
        old.iter()
            .filter(|e| !new.contains(e))
            .map(|e| edge(e, EdgeStatus::Removed)),
    );
    out
}

const MAX_CONTEXT_FILES: usize = 300;

/// Unchanged functions at `head_commit` that mention a changed type or
/// constant, found with `git grep` and tree-sitter, so a type change shows up
/// in the path of the code that uses it.
fn context_nodes(repo: &Path, head_commit: &str, nodes: &[Node]) -> Result<Vec<Node>, String> {
    let mut out: Vec<Node> = Vec::new();
    for (language, pattern) in [("go", "*.go"), ("rust", "*.rs")] {
        let names: Vec<&str> = nodes
            .iter()
            .filter(|n| {
                matches!(n.kind, Kind::Type | Kind::Const) && n.status != NodeStatus::Removed
            })
            .filter(|n| parts(&n.id).0 == language)
            .map(|n| parts(&n.id).2)
            .collect();
        if names.is_empty() {
            continue;
        }
        let mut files: Vec<String> = Vec::new();
        for name in &names {
            for f in git::files_containing(repo, head_commit, name, pattern)? {
                if !files.contains(&f) {
                    files.push(f);
                }
            }
        }
        files.truncate(MAX_CONTEXT_FILES);
        for path in files {
            let source = git::show(repo, head_commit, &path)?;
            for (name, symbol) in with_ids(&symbols::extract(language, &path, &source)) {
                let id = format!("{language}:{name}");
                let uses_changed = matches!(symbol.kind, Kind::Function | Kind::Method)
                    && symbol.refs.iter().any(|r| names.contains(&r.as_str()));
                if !uses_changed || nodes.iter().chain(out.iter()).any(|n| n.id == id) {
                    continue;
                }
                let range = Range {
                    start: symbol.start,
                    len: symbol.end - symbol.start + 1,
                };
                out.push(Node {
                    is_test: diff::is_test(&path) || name.split("::").any(|s| s == "tests"),
                    id,
                    kind: symbol.kind,
                    status: NodeStatus::Context,
                    file: path.clone(),
                    old: None,
                    new: Some(range),
                    hunks: Vec::new(),
                    old_calls: Vec::new(),
                    new_calls: Vec::new(),
                    new_name_at: Some(symbol.name_at),
                    old_refs: symbol.refs.clone(),
                    new_refs: symbol.refs.clone(),
                    old_imports: Vec::new(),
                    new_imports: Vec::new(),
                });
            }
        }
    }
    Ok(out)
}
