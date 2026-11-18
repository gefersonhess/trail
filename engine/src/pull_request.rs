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

#[derive(Deserialize)]
pub struct ReviewComment {
    path: String,
    side: Side,
    line: u32,
    last: Option<u32>,
    body: String,
}

#[derive(Deserialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Side {
    Old,
    New,
}

#[derive(Serialize)]
pub struct Submitted {
    url: String,
    inline: usize,
    in_body: usize,
    /// Positions, in the comments given, of those posted inline.
    inline_comments: Vec<usize>,
}

/// Line ranges of one side of a file that GitHub accepts comments on: the
/// hunks of its own diff, context lines included.
type Ranges = Vec<(u32, u32)>;

/// Parses `@@ -a,b +c,d @@` headers into old and new line ranges.
fn hunk_ranges(patch: &str) -> (Ranges, Ranges) {
    let (mut old, mut new) = (Vec::new(), Vec::new());
    for header in patch.lines().filter(|l| l.starts_with("@@ ")) {
        let mut parts = header.split_whitespace().skip(1);
        let mut range = |prefix: char| -> Option<(u32, u32)> {
            let spec = parts.next()?.strip_prefix(prefix)?;
            let (start, len) = spec.split_once(',').unwrap_or((spec, "1"));
            let (start, len): (u32, u32) = (start.parse().ok()?, len.parse().ok()?);
            (len > 0).then(|| (start, start + len - 1))
        };
        if let Some(r) = range('-') {
            old.push(r);
        }
        if let Some(r) = range('+') {
            new.push(r);
        }
    }
    (old, new)
}

fn gh_command() -> String {
    std::env::var("TRAIL_GH").unwrap_or_else(|_| "gh".to_string())
}

/// The host and `owner/repo` of a pull request's url,
/// `https://github.com/owner/repo/pull/7`.
fn repository_of(url: &str, number: u32) -> Result<(String, String), String> {
    let unexpected = || format!("unexpected pull request url {url}");
    let base = url
        .strip_suffix(&format!("/pull/{number}"))
        .ok_or_else(unexpected)?;
    let (_, rest) = base.split_once("://").ok_or_else(unexpected)?;
    match rest.split('/').collect::<Vec<_>>()[..] {
        [host, owner, repo] if !host.is_empty() && !owner.is_empty() && !repo.is_empty() => {
            Ok((host.to_string(), format!("{owner}/{repo}")))
        }
        _ => Err(unexpected()),
    }
}

/// Posts one review on a pull request: `event` (`APPROVE`, `REQUEST_CHANGES`,
/// `COMMENT`, or none for a pending review), the overall `body`, and the
/// comments as inline comments where GitHub's diff has their lines. The
/// others are listed at the end of the body, since GitHub refuses them inline.
pub fn submit_review(
    repo: &Path,
    url: &str,
    number: u32,
    commit: &str,
    event: Option<&str>,
    body: &str,
    comments: &[ReviewComment],
) -> Result<Submitted, String> {
    let gh = gh_command();
    // `gh api` goes to github.com unless told otherwise, even inside a
    // repository on GitHub Enterprise, where `gh pr view` finds the host itself.
    let (host, repository) = repository_of(url, number)?;
    let out = Command::new(&gh)
        .current_dir(repo)
        .args([
            "api",
            "--hostname",
            &host,
            &format!("repos/{repository}/pulls/{number}/files"),
            "--paginate",
            "--jq",
            ".[] | [.filename, (.patch // \"\")]",
        ])
        .output()
        .map_err(|e| format!("running {gh}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{gh} api pulls/{number}/files: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let mut ranges: std::collections::HashMap<String, (Ranges, Ranges)> = Default::default();
    for file in serde_json::Deserializer::from_slice(&out.stdout).into_iter::<(String, String)>() {
        let (name, patch) = file.map_err(|e| format!("reading {gh} output: {e}"))?;
        ranges.insert(name, hunk_ranges(&patch));
    }

    let mut inline = Vec::new();
    let mut inline_comments = Vec::new();
    let mut elsewhere = Vec::new();
    for (index, c) in comments.iter().enumerate() {
        let last = c.last.unwrap_or(c.line);
        let fits = ranges.get(&c.path).is_some_and(|(old, new)| {
            let side = if c.side == Side::Old { old } else { new };
            side.iter().any(|&(a, b)| a <= c.line && last <= b)
        });
        if !fits {
            let lines = if last > c.line {
                format!("{}-{last}", c.line)
            } else {
                c.line.to_string()
            };
            let removed = if c.side == Side::Old {
                " (removed)"
            } else {
                ""
            };
            elsewhere.push(format!("- `{}` line {lines}{removed}: {}", c.path, c.body));
            continue;
        }
        let side = if c.side == Side::Old { "LEFT" } else { "RIGHT" };
        let mut comment =
            serde_json::json!({ "path": c.path, "body": c.body, "line": last, "side": side });
        if last > c.line {
            comment["start_line"] = c.line.into();
            comment["start_side"] = side.into();
        }
        inline.push(comment);
        inline_comments.push(index);
    }

    let mut text = body.trim().to_string();
    if !elsewhere.is_empty() {
        if !text.is_empty() {
            text.push_str("\n\n");
        }
        text.push_str("Comments on lines outside the diff:\n\n");
        text.push_str(&elsewhere.join("\n"));
    }
    let mut payload = serde_json::json!({ "commit_id": commit, "body": text, "comments": inline });
    if let Some(event) = event {
        payload["event"] = event.into();
    }

    let mut child = Command::new(&gh)
        .current_dir(repo)
        .args([
            "api",
            "--hostname",
            &host,
            "--method",
            "POST",
            &format!("repos/{repository}/pulls/{number}/reviews"),
            "--input",
            "-",
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("running {gh}: {e}"))?;
    {
        use std::io::Write;
        let mut stdin = child.stdin.take().expect("stdin is piped");
        stdin
            .write_all(payload.to_string().as_bytes())
            .map_err(|e| format!("writing to {gh}: {e}"))?;
    }
    let out = child
        .wait_with_output()
        .map_err(|e| format!("running {gh}: {e}"))?;
    if !out.status.success() {
        let stdout = String::from_utf8_lossy(&out.stdout);
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "{gh} api pulls/{number}/reviews: {} {}",
            stderr.trim(),
            stdout.trim()
        ));
    }
    #[derive(Deserialize)]
    struct Posted {
        html_url: String,
    }
    let posted: Posted =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("reading {gh} output: {e}"))?;
    log(&format!(
        "submitted a review on pull request {number}: {} inline, {} in the body",
        inline.len(),
        elsewhere.len()
    ));
    Ok(Submitted {
        url: posted.html_url,
        inline: inline.len(),
        in_body: elsewhere.len(),
        inline_comments,
    })
}

const THREADS_QUERY: &str =
    "query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $after) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id isResolved isOutdated path line startLine originalLine diffSide
          comments(first: 100) {
            nodes { author { login } body createdAt url diffHunk }
          }
        }
      }
    }
  }
}";

#[derive(Serialize)]
pub struct Thread {
    id: String,
    path: String,
    side: &'static str,
    line: Option<u32>,
    start_line: Option<u32>,
    original_line: Option<u32>,
    resolved: bool,
    outdated: bool,
    diff_hunk: String,
    comments: Vec<ThreadComment>,
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all(deserialize = "camelCase"))]
pub struct ThreadComment {
    #[serde(deserialize_with = "login")]
    author: String,
    body: String,
    created_at: String,
    url: String,
    #[serde(skip_serializing, default)]
    diff_hunk: String,
}

/// A deleted account comes back without an author.
fn login<'de, D: serde::Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    #[derive(Deserialize)]
    struct Author {
        login: String,
    }
    let author: Option<Author> = Option::deserialize(d)?;
    Ok(author.map_or_else(|| "ghost".to_string(), |a| a.login))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawThread {
    id: String,
    is_resolved: bool,
    is_outdated: bool,
    path: String,
    line: Option<u32>,
    start_line: Option<u32>,
    original_line: Option<u32>,
    diff_side: String,
    comments: Nodes<ThreadComment>,
}

#[derive(Deserialize)]
struct Nodes<T> {
    nodes: Vec<T>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Page {
    page_info: PageInfo,
    nodes: Vec<RawThread>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PageInfo {
    has_next_page: bool,
    end_cursor: Option<String>,
}

/// The review threads of a pull request, from GitHub's GraphQL API, the only
/// one that says whether a thread is resolved or outdated.
pub fn review_threads(repo: &Path, url: &str, number: u32) -> Result<Vec<Thread>, String> {
    let gh = gh_command();
    let (host, repository) = repository_of(url, number)?;
    let (owner, name) = repository.split_once('/').expect("owner/repo");
    let mut threads = Vec::new();
    let mut after: Option<String> = None;
    loop {
        let mut args = vec![
            "api".to_string(),
            "graphql".to_string(),
            "--hostname".to_string(),
            host.clone(),
            "-F".to_string(),
            format!("owner={owner}"),
            "-F".to_string(),
            format!("name={name}"),
            "-F".to_string(),
            format!("number={number}"),
        ];
        if let Some(cursor) = &after {
            args.extend(["-f".to_string(), format!("after={cursor}")]);
        }
        args.extend(["-f".to_string(), format!("query={THREADS_QUERY}")]);
        let out = Command::new(&gh)
            .current_dir(repo)
            .args(&args)
            .output()
            .map_err(|e| format!("running {gh}: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "{gh} api graphql (review threads of {number}): {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        #[derive(Deserialize)]
        struct Response {
            data: Data,
        }
        #[derive(Deserialize)]
        struct Data {
            repository: Repository,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct Repository {
            pull_request: PullRequestThreads,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase")]
        struct PullRequestThreads {
            review_threads: Page,
        }
        let page = serde_json::from_slice::<Response>(&out.stdout)
            .map_err(|e| format!("reading {gh} output: {e}"))?
            .data
            .repository
            .pull_request
            .review_threads;
        for raw in page.nodes {
            let diff_hunk = raw
                .comments
                .nodes
                .first()
                .map(|c| c.diff_hunk.clone())
                .unwrap_or_default();
            threads.push(Thread {
                id: raw.id,
                path: raw.path,
                side: if raw.diff_side == "LEFT" {
                    "old"
                } else {
                    "new"
                },
                line: raw.line,
                start_line: raw.start_line,
                original_line: raw.original_line,
                resolved: raw.is_resolved,
                outdated: raw.is_outdated,
                diff_hunk,
                comments: raw.comments.nodes,
            });
        }
        match (page.page_info.has_next_page, page.page_info.end_cursor) {
            (true, Some(cursor)) => after = Some(cursor),
            _ => break,
        }
    }
    log(&format!(
        "read {} review threads of pull request {number}",
        threads.len()
    ));
    Ok(threads)
}

const REPLY_MUTATION: &str = "mutation($threadId: ID!, $body: String!) {
  addPullRequestReviewThreadReply(input: {pullRequestReviewThreadId: $threadId, body: $body}) { comment { url } }
}";
const RESOLVE_MUTATION: &str = "mutation($threadId: ID!) { resolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } } }";
const REOPEN_MUTATION: &str = "mutation($threadId: ID!) { unresolveReviewThread(input: {threadId: $threadId}) { thread { isResolved } } }";

/// Runs one GraphQL request through `gh` on `host`, with string variables.
fn graphql(repo: &Path, host: &str, vars: &[(&str, &str)], query: &str) -> Result<(), String> {
    let gh = gh_command();
    let mut args = vec![
        "api".to_string(),
        "graphql".to_string(),
        "--hostname".to_string(),
        host.to_string(),
    ];
    for (name, value) in vars {
        args.extend(["-f".to_string(), format!("{name}={value}")]);
    }
    args.extend(["-f".to_string(), format!("query={query}")]);
    let out = Command::new(&gh)
        .current_dir(repo)
        .args(&args)
        .output()
        .map_err(|e| format!("running {gh}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{gh} api graphql: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(())
}

/// Replies to a review thread, then resolves or reopens it when asked
/// (`state` is `resolve` or `reopen`). An empty `body` posts no reply.
pub fn update_thread(
    repo: &Path,
    url: &str,
    number: u32,
    thread: &str,
    body: &str,
    state: Option<&str>,
) -> Result<(), String> {
    let (host, _) = repository_of(url, number)?;
    let body = body.trim();
    if !body.is_empty() {
        graphql(
            repo,
            &host,
            &[("threadId", thread), ("body", body)],
            REPLY_MUTATION,
        )?;
    }
    match state {
        Some("resolve") => graphql(repo, &host, &[("threadId", thread)], RESOLVE_MUTATION)?,
        Some("reopen") => graphql(repo, &host, &[("threadId", thread)], REOPEN_MUTATION)?,
        Some(other) => return Err(format!("unknown thread state {other}")),
        None => {}
    }
    log(&format!(
        "updated review thread {thread} of pull request {number}: reply {}, {}",
        if body.is_empty() { "none" } else { "posted" },
        state.unwrap_or("state unchanged")
    ));
    Ok(())
}
