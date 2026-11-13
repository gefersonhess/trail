use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::Serialize;

use crate::diff::{self, Hunk};
use crate::difftastic::{self, Outcome};
use crate::git;

/// Two versions of a file aligned row by row. Line numbers are 1-based; a
/// `None` in a row is filler where that side has no matching line.
#[derive(Serialize)]
pub struct SideBySide {
    engine: &'static str,
    old_lines: Vec<String>,
    new_lines: Vec<String>,
    rows: Vec<(Option<u32>, Option<u32>)>,
    old_changes: Vec<LineChange>,
    new_changes: Vec<LineChange>,
}

/// A changed line, with the byte ranges of its changed tokens when known.
#[derive(Serialize)]
struct LineChange {
    line: u32,
    spans: Vec<(usize, usize)>,
}

pub fn compute(
    repo: &Path,
    base_commit: &str,
    head_commit: &str,
    old_path: Option<&str>,
    new_path: Option<&str>,
) -> Result<SideBySide, String> {
    let base = git::commit(repo, base_commit)?;
    let head = git::commit(repo, head_commit)?;
    let name = new_path
        .or(old_path)
        .ok_or("old_path or new_path is required")?;
    let read = |commit: &str, path: Option<&str>| -> Result<String, String> {
        path.map_or(Ok(String::new()), |p| git::show(repo, commit, p))
    };
    let old = read(&base, old_path)?;
    let new = read(&head, new_path)?;
    let paths: Vec<&str> = old_path.into_iter().chain(new_path).collect();
    let hunks = diff::compute(repo, &base, &head, &paths)?.hunks;
    let old_lines: Vec<String> = old.lines().map(str::to_string).collect();
    let new_lines: Vec<String> = new.lines().map(str::to_string).collect();
    let (line_rows, old_changed, new_changed) =
        rows_from_hunks(old_lines.len() as u32, new_lines.len() as u32, &hunks);

    let structural = match (old_path, new_path) {
        (Some(_), Some(_)) => difftastic::diff(name, &old, &new),
        _ => None,
    };
    let whole = |lines: BTreeSet<u32>| -> Vec<LineChange> {
        lines
            .into_iter()
            .map(|line| LineChange {
                line,
                spans: Vec::new(),
            })
            .collect()
    };
    let spans = |map: BTreeMap<u32, Vec<(usize, usize)>>| -> Vec<LineChange> {
        map.into_iter()
            .map(|(line, spans)| LineChange { line, spans })
            .collect()
    };
    let (engine, rows, old_changes, new_changes) = match structural {
        Some(Outcome::Changed(s)) => ("difftastic", s.rows, spans(s.old), spans(s.new)),
        Some(Outcome::Unchanged) => ("difftastic", line_rows, Vec::new(), Vec::new()),
        None => ("text", line_rows, whole(old_changed), whole(new_changed)),
    };
    Ok(SideBySide {
        engine,
        old_lines,
        new_lines,
        rows,
        old_changes,
        new_changes,
    })
}

type Rows = (
    Vec<(Option<u32>, Option<u32>)>,
    BTreeSet<u32>,
    BTreeSet<u32>,
);

/// Aligns unchanged lines one to one and pairs the removed and added lines of
/// each hunk side by side.
fn rows_from_hunks(old_len: u32, new_len: u32, hunks: &[Hunk]) -> Rows {
    let mut rows = Vec::new();
    let (mut old_changed, mut new_changed) = (BTreeSet::new(), BTreeSet::new());
    let (mut o, mut n) = (1, 1);
    for h in hunks {
        let first = |r: diff::Range| if r.len == 0 { r.start + 1 } else { r.start };
        let (old_first, new_first) = (first(h.old), first(h.new));
        while o < old_first && n < new_first {
            rows.push((Some(o), Some(n)));
            o += 1;
            n += 1;
        }
        for i in 0..h.old.len.max(h.new.len) {
            let old = (i < h.old.len).then_some(o + i);
            let new = (i < h.new.len).then_some(n + i);
            old_changed.extend(old);
            new_changed.extend(new);
            rows.push((old, new));
        }
        o += h.old.len;
        n += h.new.len;
    }
    while o <= old_len || n <= new_len {
        rows.push(((o <= old_len).then_some(o), (n <= new_len).then_some(n)));
        o += 1;
        n += 1;
    }
    (rows, old_changed, new_changed)
}
