use std::collections::HashMap;
use std::path::Path;

use serde::Serialize;

use crate::diff::{self, File, Hunk, Range, Status};
use crate::git;
use crate::symbols::{self, Call, Kind, Symbol, Via};

#[derive(Serialize)]
pub struct Review {
    pub base_commit: String,
    pub head_commit: String,
    pub files: Vec<File>,
    pub hunks: Vec<Hunk>,
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
}

#[derive(Serialize)]
pub struct Node {
    id: String,
    kind: Kind,
    status: NodeStatus,
    file: String,
    old: Option<Range>,
    new: Option<Range>,
    hunks: Vec<String>,
    is_test: bool,
    #[serde(skip)]
    old_calls: Vec<Call>,
    #[serde(skip)]
    new_calls: Vec<Call>,
}

#[derive(Serialize)]
pub struct Edge {
    from: String,
    to: String,
    status: EdgeStatus,
    source: &'static str,
}

#[derive(Serialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum EdgeStatus {
    Added,
    Removed,
    Unchanged,
}

#[derive(Serialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum NodeStatus {
    Added,
    Modified,
    Removed,
}

/// Reviews `head` against its merge base with `base`, like `git diff base...head`,
/// so changes that landed on `base` after the branch point are not shown.
pub fn open(repo: &Path, base: &str, head: &str) -> Result<Review, String> {
    let head_commit = git::commit(repo, head)?;
    let base_tip = git::commit(repo, base)?;
    let base_commit = git::run(repo, &["merge-base", &base_tip, &head_commit])?
        .trim()
        .to_string();
    let diff = diff::compute(repo, &base_commit, &head_commit)?;
    let mut nodes = Vec::new();
    for file in &diff.files {
        let Some(language) = file.language.filter(|_| !file.binary) else {
            continue;
        };
        let old_path = file.old_path.as_deref().unwrap_or(&file.path);
        let side = |commit: &str, path: &str, present: bool| -> Result<Vec<Symbol>, String> {
            if !present {
                return Ok(Vec::new());
            }
            Ok(symbols::extract(
                language,
                path,
                &git::show(repo, commit, path)?,
            ))
        };
        let old = side(&base_commit, old_path, file.status != Status::Added)?;
        let new = side(&head_commit, &file.path, file.status != Status::Deleted)?;
        let hunks: Vec<&Hunk> = diff.hunks.iter().filter(|h| h.file == file.path).collect();
        nodes.extend(changed_nodes(file, language, &old, &new, &hunks));
    }
    Ok(Review {
        base_commit,
        head_commit,
        files: diff.files,
        hunks: diff.hunks,
        edges: edges(&nodes),
        nodes,
    })
}

fn changed_nodes(
    file: &File,
    language: &str,
    old: &[Symbol],
    new: &[Symbol],
    hunks: &[&Hunk],
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
    let old = side_edges(nodes, |n| n.status != NodeStatus::Added, |n| &n.old_calls);
    let new = side_edges(nodes, |n| n.status != NodeStatus::Removed, |n| &n.new_calls);
    let edge = |(from, to): &(&str, &str), status| Edge {
        from: from.to_string(),
        to: to.to_string(),
        status,
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
    calls: impl Fn(&Node) -> &[Call],
) -> Vec<(&str, &str)> {
    let mut out = Vec::new();
    for caller in nodes.iter().filter(|n| present(n)) {
        for call in calls(caller) {
            for target in targets(nodes, present, caller, call) {
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
    let with_parent = |parent: &str, kind: Option<Kind>| -> Vec<&'a Node> {
        named
            .iter()
            .copied()
            .filter(|n| parts(&n.id).1 == parent && kind.is_none_or(|k| n.kind == k))
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
        Via::Plain if language == "go" => with_parent(caller_parent, Some(Kind::Function)),
        Via::Plain => first_nonempty(
            with_parent(caller_parent, Some(Kind::Function)),
            of_kind(Kind::Function),
        ),
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

/// Splits `go:auth.Store.Save#2` into language, parent (`Store`) and name (`Save`).
fn parts(id: &str) -> (&str, &str, &str) {
    let (language, path) = id.split_once(':').unwrap_or(("", id));
    let path = path.split_once('#').map_or(path, |(p, _)| p);
    let mut segments = path.rsplit(if language == "rust" { "::" } else { "." });
    let name = segments.next().unwrap_or("");
    (language, segments.next().unwrap_or(""), name)
}
