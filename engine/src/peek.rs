use std::path::Path;

use serde::Serialize;

use crate::git;
use crate::symbols::{self, Kind};

const MAX_FILES: usize = 300;

#[derive(Serialize)]
pub struct Peek {
    matches: Vec<Match>,
}

/// A function or method named like the one asked for. Lines are 1-based.
#[derive(Serialize)]
struct Match {
    path: String,
    name: String,
    kind: Kind,
    start: u32,
    end: u32,
    lines: Vec<String>,
}

/// Finds functions and methods called `name` at `commit` with tree-sitter,
/// best match first: the qualifier written before the name (`auth.` or
/// `Hasher::`) names its package or type, then the same file, then the same
/// directory as `from_path`.
pub fn find(
    repo: &Path,
    commit: &str,
    language: &str,
    name: &str,
    qualifier: Option<&str>,
    from_path: &str,
) -> Result<Peek, String> {
    let commit = git::commit(repo, commit)?;
    if name.is_empty() || !name.chars().all(|c| c.is_alphanumeric() || c == '_') {
        return Err(format!("invalid name {name:?}"));
    }
    let (pattern, separator) = match language {
        "go" => ("*.go", "."),
        "rust" => ("*.rs", "::"),
        _ => return Err(format!("unsupported language {language:?}")),
    };
    let mut files = git::files_containing(repo, &commit, name, pattern)?;
    files.truncate(MAX_FILES);
    let from_dir = Path::new(from_path).parent();

    let mut ranked = Vec::new();
    for path in files {
        let source = git::show(repo, &commit, &path)?;
        let lines: Vec<&str> = source.lines().collect();
        for symbol in symbols::extract(language, &path, &source) {
            let mut segments = symbol.name.rsplit(separator);
            if segments.next() != Some(name) {
                continue;
            }
            let parent = segments.next();
            let rank = (
                qualifier.is_some() && parent != qualifier,
                path != from_path,
                Path::new(&path).parent() != from_dir,
            );
            let body = lines
                .get(symbol.start as usize - 1..symbol.end as usize)
                .unwrap_or_default()
                .iter()
                .map(|l| l.to_string())
                .collect();
            ranked.push((
                rank,
                Match {
                    path: path.clone(),
                    name: symbol.name,
                    kind: symbol.kind,
                    start: symbol.start,
                    end: symbol.end,
                    lines: body,
                },
            ));
        }
    }
    ranked.sort_by(|a, b| {
        a.0.cmp(&b.0)
            .then_with(|| (&a.1.path, a.1.start).cmp(&(&b.1.path, b.1.start)))
    });
    Ok(Peek {
        matches: ranked.into_iter().map(|(_, m)| m).collect(),
    })
}
