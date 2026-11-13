use std::collections::HashMap;
use std::path::Path;

use serde::Serialize;

use crate::diff::{self, File, Hunk, Range, Status};
use crate::difftastic::{self, Outcome};
use crate::git;
use crate::paths;
use crate::symbols::{self, Call, Kind, Symbol, Via};

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
}

#[derive(Serialize)]
pub struct Edge {
    pub from: String,
    pub to: String,
    pub status: EdgeStatus,
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
}

/// Reviews `head` against its merge base with `base`, like `git diff base...head`,
/// so changes that landed on `base` after the branch point are not shown.
pub fn open(repo: &Path, base: &str, head: &str) -> Result<Review, String> {
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
        nodes.extend(changed_nodes(file, language, &old, &new, &hunks));
    }
    diff.hunks.retain(|h| !formatting_only.contains(&h.id));
    let hunks = &diff.hunks;
    diff.files.retain(|f| {
        f.status != Status::Modified || f.binary || hunks.iter().any(|h| h.file == f.path)
    });
    let edges = edges(&nodes);
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
