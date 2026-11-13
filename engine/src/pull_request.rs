use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::git;
use crate::rpc::log;

#[derive(Serialize)]
pub struct PullRequest {
    number: u32,
    title: String,
    url: String,
    base: String,
    head: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct View {
    base_ref_name: String,
    head_ref_oid: String,
    title: String,
    url: String,
}

/// Finds a GitHub pull request's base branch and head with `gh`, fetches both
/// from the pull request's repository into `refs/trail/pull/<n>/`, and returns
/// their commits. Everything after that is the same local review as for
/// branches.
pub fn fetch(repo: &Path, number: u32) -> Result<PullRequest, String> {
    let gh = std::env::var("TRAIL_GH").unwrap_or_else(|_| "gh".to_string());
    let out = Command::new(&gh)
        .current_dir(repo)
        .args([
            "pr",
            "view",
            &number.to_string(),
            "--json",
            "baseRefName,headRefOid,title,url",
        ])
        .output()
        .map_err(|e| format!("running {gh}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{gh} pr view {number}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let view: View =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("reading {gh} output: {e}"))?;
    if view.base_ref_name.starts_with('-') || view.base_ref_name.contains(char::is_whitespace) {
        return Err(format!("unexpected base branch {:?}", view.base_ref_name));
    }
    let remote = view
        .url
        .strip_suffix(&format!("/pull/{number}"))
        .ok_or_else(|| format!("unexpected pull request url {}", view.url))?;
    log(&format!("fetching pull request {number} from {remote}"));
    let head_ref = format!("refs/trail/pull/{number}/head");
    let base_ref = format!("refs/trail/pull/{number}/base");
    git::run(
        repo,
        &[
            "fetch",
            "--quiet",
            "--no-tags",
            "--end-of-options",
            remote,
            &format!("+refs/pull/{number}/head:{head_ref}"),
            &format!("+refs/heads/{}:{base_ref}", view.base_ref_name),
        ],
    )?;
    let head = git::commit(repo, &head_ref)?;
    if head != view.head_ref_oid {
        log(&format!(
            "pull request {number} head moved to {head} while fetching"
        ));
    }
    Ok(PullRequest {
        number,
        title: view.title,
        url: view.url,
        base: git::commit(repo, &base_ref)?,
        head,
    })
}
