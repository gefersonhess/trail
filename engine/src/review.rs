use std::collections::HashMap;
use std::path::Path;

use serde::Serialize;

use crate::diff::{self, File, Hunk, Range, Status};
use crate::git;
use crate::symbols::{self, Kind, Symbol};

#[derive(Serialize)]
pub struct Review {
    pub base_commit: String,
    pub head_commit: String,
    pub files: Vec<File>,
    pub hunks: Vec<Hunk>,
    pub nodes: Vec<Node>,
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
}

#[derive(Serialize, Clone, Copy)]
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
                is_test: file.is_test || id.contains("::tests::"),
                id,
                kind,
                status,
                file: file.path.clone(),
                old: old.map(span),
                new: new.map(span),
                hunks: hunks.iter().map(|h| h.id.clone()).collect(),
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
