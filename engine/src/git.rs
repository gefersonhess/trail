use std::path::Path;
use std::process::Command;

pub fn run(repo: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["-c", "core.quotePath=false"])
        .args(args)
        .output()
        .map_err(|e| format!("running git: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn open(repo: &Path) -> Result<gix::Repository, String> {
    gix::discover(repo).map_err(|e| format!("opening repository {}: {e}", repo.display()))
}

fn resolve<'r>(repository: &'r gix::Repository, rev: &str) -> Result<gix::Commit<'r>, String> {
    if rev.is_empty() || rev.starts_with('-') {
        return Err(format!("invalid revision {rev:?}"));
    }
    repository
        .rev_parse_single(rev)
        .ok()
        .and_then(|id| id.object().ok())
        .and_then(|object| object.peel_to_commit().ok())
        .ok_or_else(|| format!("unknown revision {rev:?}"))
}

pub fn commit(repo: &Path, rev: &str) -> Result<String, String> {
    Ok(resolve(&open(repo)?, rev)?.id.to_string())
}

pub fn merge_base(repo: &Path, one: &str, two: &str) -> Result<String, String> {
    let repository = open(repo)?;
    let (a, b) = (resolve(&repository, one)?.id, resolve(&repository, two)?.id);
    repository
        .merge_base(a, b)
        .map_err(|e| format!("finding the merge base: {e}"))?
        .map(|id| id.to_string())
        .ok_or_else(|| format!("{one} and {two} have no common history"))
}

pub fn tree<'r>(repository: &'r gix::Repository, rev: &str) -> Result<gix::Tree<'r>, String> {
    resolve(repository, rev)?
        .tree()
        .map_err(|e| format!("reading the tree of {rev}: {e}"))
}

pub fn blob(repository: &gix::Repository, id: gix::ObjectId) -> Result<Vec<u8>, String> {
    Ok(repository
        .find_object(id)
        .map_err(|e| format!("reading {id}: {e}"))?
        .detach()
        .data)
}

pub fn show(repo: &Path, commit: &str, path: &str) -> Result<String, String> {
    let repository = open(repo)?;
    let entry = tree(&repository, commit)?
        .lookup_entry_by_path(path)
        .map_err(|e| format!("looking up {path}: {e}"))?
        .ok_or_else(|| format!("{path} does not exist at {commit}"))?;
    Ok(String::from_utf8_lossy(&blob(&repository, entry.object_id())?).into_owned())
}

/// Paths at `commit` matching `pathspec` (`*.go`) that contain `word` as a whole word.
pub fn files_containing(
    repo: &Path,
    commit: &str,
    word: &str,
    pathspec: &str,
) -> Result<Vec<String>, String> {
    let repository = open(repo)?;
    let extension = pathspec.strip_prefix('*').unwrap_or(pathspec);
    let mut recorder = gix::traverse::tree::Recorder::default();
    tree(&repository, commit)?
        .traverse()
        .breadthfirst(&mut recorder)
        .map_err(|e| format!("listing files at {commit}: {e}"))?;
    let mut out = Vec::new();
    for entry in recorder.records {
        let path = entry.filepath.to_string();
        if !entry.mode.is_blob() || !path.ends_with(extension) {
            continue;
        }
        if contains_word(&blob(&repository, entry.oid)?, word.as_bytes()) {
            out.push(path);
        }
    }
    out.sort();
    Ok(out)
}

fn contains_word(data: &[u8], word: &[u8]) -> bool {
    let ident = |b: u8| b.is_ascii_alphanumeric() || b == b'_';
    data.windows(word.len()).enumerate().any(|(i, w)| {
        w == word
            && (i == 0 || !ident(data[i - 1]))
            && data.get(i + word.len()).is_none_or(|b| !ident(*b))
    })
}
