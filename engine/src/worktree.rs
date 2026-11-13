use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::git;
use crate::rpc::log;

#[derive(Serialize)]
pub struct Checkout {
    path: PathBuf,
    worktree: bool,
}

/// A directory with `commit` checked out, for tools that need real files such
/// as language servers. That is the repository itself when its HEAD is already
/// `commit`; otherwise one detached worktree per repository under the cache
/// directory, moved to `commit` and reused across reviews so build caches and
/// language server indexes stay warm. Local edits in that worktree are discarded.
pub fn checkout(repo: &Path, commit: &str) -> Result<Checkout, String> {
    let commit = git::commit(repo, commit)?;
    let top = git::run(repo, &["rev-parse", "--show-toplevel"])?
        .trim()
        .to_string();
    if git::commit(repo, "HEAD").ok().as_deref() == Some(commit.as_str()) {
        return Ok(Checkout {
            path: PathBuf::from(top),
            worktree: false,
        });
    }
    let dir = cache_dir()?
        .join("trail")
        .join("worktrees")
        .join(top.replace(['/', '\\', ':'], "-"));
    let dir_str = dir.to_str().ok_or("cache path is not valid UTF-8")?;
    if dir.join(".git").exists() {
        log(&format!("moving review worktree {dir_str} to {commit}"));
        git::run(
            &dir,
            &["checkout", "--quiet", "--detach", "--force", &commit],
        )?;
    } else {
        log(&format!("creating review worktree {dir_str} at {commit}"));
        std::fs::create_dir_all(dir.parent().expect("has parent")).map_err(|e| e.to_string())?;
        git::run(repo, &["worktree", "prune"])?;
        git::run(
            repo,
            &[
                "worktree", "add", "--quiet", "--detach", "--force", dir_str, &commit,
            ],
        )?;
    }
    Ok(Checkout {
        path: dir,
        worktree: true,
    })
}

fn cache_dir() -> Result<PathBuf, String> {
    if let Some(dir) = std::env::var_os("XDG_CACHE_HOME").filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".cache"))
        .ok_or_else(|| "neither XDG_CACHE_HOME nor HOME is set".to_string())
}
