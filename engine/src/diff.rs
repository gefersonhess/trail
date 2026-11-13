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

/// Diffs two commits' trees with rename detection, ignoring whitespace within
/// lines like `git diff --ignore-all-space --unified=0`. `paths` limits it to
/// changes touching those paths when not empty.
pub fn compute(repo: &Path, from: &str, to: &str, paths: &[&str]) -> Result<Diff, String> {
    let repository = git::open(repo)?;
    let old_tree = git::tree(&repository, from)?;
    let new_tree = git::tree(&repository, to)?;
    let options = gix::diff::Options::default().with_rewrites(Some(gix::diff::Rewrites::default()));
    let changes = repository
        .diff_tree_to_tree(&old_tree, &new_tree, options)
        .map_err(|e| format!("diffing trees: {e}"))?;
    let mut diff = Diff {
        files: Vec::new(),
        hunks: Vec::new(),
    };
    let mut seen_ids = HashMap::new();
    let mut files = Vec::new();
    for change in changes {
        use gix::object::tree::diff::ChangeDetached as Change;
        let (status, old_path, path, old_id, new_id) = match change {
            Change::Addition {
                location,
                entry_mode,
                id,
                ..
            } if entry_mode.is_blob() => (Status::Added, None, location, None, Some(id)),
            Change::Deletion {
                location,
                entry_mode,
                id,
                ..
            } if entry_mode.is_blob() => (Status::Deleted, None, location, Some(id), None),
            Change::Modification {
                location,
                previous_entry_mode,
                previous_id,
                entry_mode,
                id,
            } if entry_mode.is_blob() && previous_entry_mode.is_blob() => (
                Status::Modified,
                None,
                location,
                Some(previous_id),
                Some(id),
            ),
            Change::Rewrite {
                source_location,
                source_id,
                location,
                entry_mode,
                id,
                copy,
                ..
            } if entry_mode.is_blob() => {
                if copy {
                    (Status::Added, None, location, None, Some(id))
                } else {
                    (
                        Status::Renamed,
                        Some(source_location.to_string()),
                        location,
                        Some(source_id),
                        Some(id),
                    )
                }
            }
            _ => continue,
        };
        let path = path.to_string();
        if !paths.is_empty()
            && !paths.contains(&path.as_str())
            && !old_path.as_deref().is_some_and(|p| paths.contains(&p))
        {
            continue;
        }
        let read = |id: Option<gix::ObjectId>| -> Result<Vec<u8>, String> {
            id.map_or(Ok(Vec::new()), |id| git::blob(&repository, id))
        };
        files.push((status, old_path, path, read(old_id)?, read(new_id)?));
    }
    files.sort_by(|a, b| a.2.cmp(&b.2));
    for (status, old_path, path, old, new) in files {
        let binary = is_binary(&old) || is_binary(&new);
        let hunks = if binary {
            Vec::new()
        } else {
            line_hunks(&old, &new)
        };
        for h in hunks {
            let removed: Vec<&str> = h.removed.iter().map(String::as_str).collect();
            let added: Vec<&str> = h.added.iter().map(String::as_str).collect();
            diff.hunks.push(Hunk {
                id: hunk_id(&path, &removed, &added, &mut seen_ids),
                file: path.clone(),
                old: h.old,
                new: h.new,
            });
        }
        diff.files.push(File {
            language: language(&path),
            is_test: is_test(&path),
            old_path: if status == Status::Renamed {
                old_path
            } else {
                None
            },
            path,
            status,
            binary,
        });
    }
    Ok(diff)
}

/// Git's rule: a NUL byte in the first 8000 bytes makes a file binary.
fn is_binary(data: &[u8]) -> bool {
    data.iter().take(8000).any(|b| *b == 0)
}

struct LineHunk {
    old: Range,
    new: Range,
    removed: Vec<String>,
    added: Vec<String>,
}

/// Lines compared with all whitespace removed, so only non-whitespace edits count.
struct Normalized(Vec<Vec<u8>>);

impl imara_diff::TokenSource for Normalized {
    type Token = Vec<u8>;
    type Tokenizer = std::vec::IntoIter<Vec<u8>>;

    fn tokenize(&self) -> Self::Tokenizer {
        self.0.clone().into_iter()
    }

    fn estimate_tokens(&self) -> u32 {
        self.0.len() as u32
    }
}

fn lines(data: &[u8]) -> Vec<&[u8]> {
    if data.is_empty() {
        return Vec::new();
    }
    let data = data.strip_suffix(b"\n").unwrap_or(data);
    data.split(|b| *b == b'\n').collect()
}

/// Re-diffs each hunk on its own lines. Myers over a whole file can give up
/// matching lines that occur very often there (blank lines), merging nearby
/// hunks that git keeps apart; within one hunk those lines are rare again.
fn refine(
    before: &[imara_diff::Token],
    after: &[imara_diff::Token],
    hunks: impl Iterator<Item = imara_diff::Hunk>,
) -> Vec<imara_diff::Hunk> {
    let mut out = Vec::new();
    for h in hunks {
        let (b, a) = (
            &before[h.before.start as usize..h.before.end as usize],
            &after[h.after.start as usize..h.after.end as usize],
        );
        if b.is_empty() || a.is_empty() || !b.iter().any(|t| a.contains(t)) {
            out.push(h);
            continue;
        }
        let input = imara_diff::InternedInput::new(Tokens(b.to_vec()), Tokens(a.to_vec()));
        let inner = imara_diff::Diff::compute(imara_diff::Algorithm::MyersMinimal, &input);
        out.extend(inner.hunks().map(|s| imara_diff::Hunk {
            before: s.before.start + h.before.start..s.before.end + h.before.start,
            after: s.after.start + h.after.start..s.after.end + h.after.start,
        }));
    }
    out
}

struct Tokens(Vec<imara_diff::Token>);

impl imara_diff::TokenSource for Tokens {
    type Token = imara_diff::Token;
    type Tokenizer = std::vec::IntoIter<imara_diff::Token>;

    fn tokenize(&self) -> Self::Tokenizer {
        self.0.clone().into_iter()
    }

    fn estimate_tokens(&self) -> u32 {
        self.0.len() as u32
    }
}

/// Hunks in `--unified=0` numbering: 1-based starts, and for an empty side the
/// line the change comes after.
fn line_hunks(old: &[u8], new: &[u8]) -> Vec<LineHunk> {
    let (old_lines, new_lines) = (lines(old), lines(new));
    let normalize = |ls: &[&[u8]]| {
        Normalized(
            ls.iter()
                .map(|l| {
                    l.iter()
                        .copied()
                        .filter(|b| !b.is_ascii_whitespace())
                        .collect()
                })
                .collect(),
        )
    };
    let input = imara_diff::InternedInput::new(normalize(&old_lines), normalize(&new_lines));
    let mut d = imara_diff::Diff::compute(imara_diff::Algorithm::Myers, &input);
    // Slide ambiguous hunks the way git's indent heuristic does, judging
    // indentation from the original lines rather than the normalized ones.
    let mut indent = HashMap::new();
    for (tokens, ls) in [(&input.before, &old_lines), (&input.after, &new_lines)] {
        for (token, line) in tokens.iter().zip(ls.iter()) {
            indent.entry(*token).or_insert_with(|| {
                imara_diff::IndentLevel::for_ascii_line(line.iter().copied(), 8)
            });
        }
    }
    d.postprocess_with_heuristic(
        &input,
        imara_diff::IndentHeuristic::new(|token| indent[&token]),
    );
    let hunks = refine(&input.before, &input.after, d.hunks());
    let text = |ls: &[&[u8]]| {
        ls.iter()
            .map(|l| String::from_utf8_lossy(l).into_owned())
            .collect()
    };
    hunks
        .into_iter()
        .map(|h| {
            let range = |r: &std::ops::Range<u32>| Range {
                start: if r.is_empty() { r.start } else { r.start + 1 },
                len: r.end - r.start,
            };
            LineHunk {
                old: range(&h.before),
                new: range(&h.after),
                removed: text(&old_lines[h.before.start as usize..h.before.end as usize]),
                added: text(&new_lines[h.after.start as usize..h.after.end as usize]),
            }
        })
        .collect()
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

fn language(path: &str) -> Option<&'static str> {
    match Path::new(path).extension()?.to_str()? {
        "go" => Some("go"),
        "rs" => Some("rust"),
        _ => None,
    }
}

pub fn is_test(path: &str) -> bool {
    path.ends_with("_test.go") || path.split('/').any(|segment| segment == "tests")
}
