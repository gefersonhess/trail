use std::collections::HashMap;
use std::path::Path;

use serde::Serialize;

use crate::git;

#[derive(Serialize)]
pub struct Diff {
    pub files: Vec<File>,
    pub hunks: Vec<Hunk>,
}

#[derive(Serialize)]
pub struct File {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
    pub status: Status,
    pub language: Option<&'static str>,
    pub is_test: bool,
    pub binary: bool,
}

#[derive(Serialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Added,
    Modified,
    Deleted,
    Renamed,
}

#[derive(Serialize)]
pub struct Hunk {
    pub id: String,
    pub file: String,
    pub old: Range,
    pub new: Range,
}

#[derive(Serialize, Clone, Copy)]
pub struct Range {
    pub start: u32,
    pub len: u32,
}

pub fn compute(repo: &Path, from: &str, to: &str) -> Result<Diff, String> {
    let patch = git::run(
        repo,
        &[
            "diff",
            "--no-color",
            "--no-ext-diff",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "--find-renames",
            "--ignore-all-space",
            "--unified=0",
            from,
            to,
            "--",
        ],
    )?;
    Ok(parse(&patch))
}

#[derive(Default)]
struct PendingFile<'a> {
    header_path: Option<String>,
    old_path: Option<String>,
    new_path: Option<String>,
    status: Option<Status>,
    binary: bool,
    hunks: Vec<PendingHunk<'a>>,
}

struct PendingHunk<'a> {
    old: Range,
    new: Range,
    removed: Vec<&'a str>,
    added: Vec<&'a str>,
}

fn parse(patch: &str) -> Diff {
    let mut diff = Diff {
        files: Vec::new(),
        hunks: Vec::new(),
    };
    let mut seen_ids = HashMap::new();
    let mut file: Option<PendingFile> = None;

    for line in patch.lines() {
        if let Some(rest) = line.strip_prefix("diff --git ") {
            if let Some(f) = file.take() {
                finish(f, &mut diff, &mut seen_ids);
            }
            file = Some(PendingFile {
                header_path: header_path(rest),
                ..Default::default()
            });
            continue;
        }
        let Some(f) = file.as_mut() else { continue };

        if let Some(h) = f.hunks.last_mut() {
            match line.as_bytes().first() {
                Some(b'-') => h.removed.push(&line[1..]),
                Some(b'+') => h.added.push(&line[1..]),
                _ => {}
            }
            if !line.starts_with("@@ ") {
                continue;
            }
        }

        if let Some(rest) = line.strip_prefix("@@ ") {
            if let Some((old, new)) = hunk_ranges(rest) {
                f.hunks.push(PendingHunk {
                    old,
                    new,
                    removed: Vec::new(),
                    added: Vec::new(),
                });
            }
        } else if line.starts_with("new file mode") {
            f.status = Some(Status::Added);
        } else if line.starts_with("deleted file mode") {
            f.status = Some(Status::Deleted);
        } else if let Some(p) = line.strip_prefix("rename from ") {
            f.old_path = Some(p.to_string());
            f.status = Some(Status::Renamed);
        } else if let Some(p) = line.strip_prefix("rename to ") {
            f.new_path = Some(p.to_string());
        } else if let Some(p) = line.strip_prefix("--- ") {
            f.old_path = side_path(p, "a/").or(f.old_path.take());
        } else if let Some(p) = line.strip_prefix("+++ ") {
            f.new_path = side_path(p, "b/").or(f.new_path.take());
        } else if line.starts_with("Binary files ") {
            f.binary = true;
        }
    }
    if let Some(f) = file.take() {
        finish(f, &mut diff, &mut seen_ids);
    }
    diff
}

fn finish(f: PendingFile, diff: &mut Diff, seen_ids: &mut HashMap<u64, u32>) {
    let status = f.status.unwrap_or(Status::Modified);
    if status == Status::Modified && f.hunks.is_empty() && !f.binary {
        return;
    }
    let Some(path) = f.new_path.clone().or(f.old_path.clone()).or(f.header_path) else {
        return;
    };
    for h in f.hunks {
        diff.hunks.push(Hunk {
            id: hunk_id(&path, &h.removed, &h.added, seen_ids),
            file: path.clone(),
            old: h.old,
            new: h.new,
        });
    }
    diff.files.push(File {
        language: language(&path),
        is_test: is_test(&path),
        old_path: if status == Status::Renamed {
            f.old_path
        } else {
            None
        },
        path,
        status,
        binary: f.binary,
    });
}

/// Hashes the file and the changed lines, not line numbers, so a hunk keeps its id
/// when other hunks shift it. Identical hunks in one file get an occurrence suffix.
fn hunk_id(path: &str, removed: &[&str], added: &[&str], seen: &mut HashMap<u64, u32>) -> String {
    let mut hash = Fnv::new();
    hash.write(path.as_bytes());
    for (marker, lines) in [(b'-', removed), (b'+', added)] {
        for line in lines {
            hash.write(&[0, marker]);
            hash.write(line.as_bytes());
        }
    }
    let base = hash.0;
    let n = seen.entry(base).or_insert(0);
    *n += 1;
    if *n == 1 {
        format!("{base:016x}")
    } else {
        format!("{base:016x}-{n}")
    }
}

/// FNV-1a: stable across Rust versions, unlike `DefaultHasher`, which matters
/// because hunk ids are persisted in review state.
struct Fnv(u64);

impl Fnv {
    fn new() -> Self {
        Fnv(0xcbf2_9ce4_8422_2325)
    }

    fn write(&mut self, bytes: &[u8]) {
        for b in bytes {
            self.0 ^= u64::from(*b);
            self.0 = self.0.wrapping_mul(0x0100_0000_01b3);
        }
    }
}

fn hunk_ranges(header: &str) -> Option<(Range, Range)> {
    let mut parts = header.split(' ');
    let old = range(parts.next()?.strip_prefix('-')?)?;
    let new = range(parts.next()?.strip_prefix('+')?)?;
    Some((old, new))
}

fn range(s: &str) -> Option<Range> {
    let (start, len) = match s.split_once(',') {
        Some((start, len)) => (start.parse().ok()?, len.parse().ok()?),
        None => (s.parse().ok()?, 1),
    };
    Some(Range { start, len })
}

fn side_path(p: &str, prefix: &str) -> Option<String> {
    let p = p.strip_suffix('\t').unwrap_or(p);
    p.strip_prefix(prefix).map(str::to_string)
}

/// Recovers the path from `a/<p> b/<p>`, used when a file has no `---`/`+++` lines
/// (binary or empty files). Renames carry their paths in `rename` lines instead.
fn header_path(rest: &str) -> Option<String> {
    let inner = rest.strip_prefix("a/")?;
    let half = inner.len().checked_sub(3)? / 2;
    let (old, new) = (inner.get(..half)?, inner.get(half..)?.strip_prefix(" b/")?);
    (old == new).then(|| old.to_string())
}

fn language(path: &str) -> Option<&'static str> {
    match Path::new(path).extension()?.to_str()? {
        "go" => Some("go"),
        "rs" => Some("rust"),
        _ => None,
    }
}

fn is_test(path: &str) -> bool {
    path.ends_with("_test.go") || path.split('/').any(|segment| segment == "tests")
}
