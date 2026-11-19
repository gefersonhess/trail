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
    author: String,
    description: String,
    base_branch: String,
    head_branch: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct View {
    base_ref_name: String,
    head_ref_name: String,
    head_ref_oid: String,
    title: String,
    url: String,
    body: String,
    #[serde(deserialize_with = "login")]
    author: String,
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
            "baseRefName,headRefName,headRefOid,title,url,body,author",
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
        author: view.author,
        description: view.body,
        base_branch: view.base_ref_name,
        head_branch: view.head_ref_name,
    })
}

#[derive(Deserialize)]
pub struct ReviewComment {
    path: String,
    side: Side,
    line: u32,
    last: Option<u32>,
    body: String,
    /// The text of the comment's first line, to find it again at the pull
    /// request's head or base when it was written on another commit.
    #[serde(default)]
    text: Option<String>,
}

/// Where a comment's lines are at `rev`: the line with its text nearest the
/// one it was written on, shifted with the rest of its lines. None when the
/// file at `rev` has no such line.
fn anchored(repo: &Path, rev: &str, c: &ReviewComment, text: &str) -> Option<(u32, Option<u32>)> {
    let source = git::show(repo, rev, &c.path).ok()?;
    let found = source
        .lines()
        .enumerate()
        .filter(|(_, l)| *l == text)
        .map(|(i, _)| i as u32 + 1)
        .min_by_key(|&l| l.abs_diff(c.line))?;
    let shift = i64::from(found) - i64::from(c.line);
    let last = c
        .last
        .map(|last| (i64::from(last) + shift).max(i64::from(found)) as u32);
    Some((found, last))
}

#[derive(Deserialize, Clone, Copy, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Side {
    Old,
    New,
}

/// A review to submit: the `submit_review` request.
#[derive(Deserialize)]
pub struct Submission {
    repo: std::path::PathBuf,
    url: String,
    number: u32,
    /// The pull request's head commit, which the comments' lines refer to.
    commit: String,
    /// The pull request's base, to find removed lines a comment is on again.
    base: Option<String>,
    event: Option<String>,
    #[serde(default)]
    body: String,
    #[serde(default)]
    comments: Vec<ReviewComment>,
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

/// The lines GitHub's diff of the pull request has, per file: (old, new).
type DiffRanges = std::collections::HashMap<String, (Ranges, Ranges)>;

fn diff_ranges(
    repo: &Path,
    host: &str,
    repository: &str,
    number: u32,
) -> Result<DiffRanges, String> {
    let gh = gh_command();
    let out = Command::new(&gh)
        .current_dir(repo)
        .args([
            "api",
            "--hostname",
            host,
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
    let mut ranges = DiffRanges::default();
    for file in serde_json::Deserializer::from_slice(&out.stdout).into_iter::<(String, String)>() {
        let (name, patch) = file.map_err(|e| format!("reading {gh} output: {e}"))?;
        ranges.insert(name, hunk_ranges(&patch));
    }
    Ok(ranges)
}

/// Where a comment goes on GitHub: its first and last line, found again by
/// its text at the head (removed lines at `left`, the merge base), and
/// whether GitHub's diff has them, which it needs to take it inline.
fn place(
    repo: &Path,
    commit: &str,
    left: Option<&str>,
    c: &ReviewComment,
    ranges: &DiffRanges,
) -> (u32, u32, bool) {
    // A comment written on an earlier commit, or before new pushes, may sit
    // on another line at the head.
    let rev = if c.side == Side::Old {
        left
    } else {
        Some(commit)
    };
    let at = match (&c.text, rev) {
        (Some(text), Some(rev)) => anchored(repo, rev, c, text),
        _ => Some((c.line, c.last)),
    };
    let (line, last) = at.map_or((c.line, c.last.unwrap_or(c.line)), |(l, last)| {
        (l, last.unwrap_or(l))
    });
    let fits = at.is_some()
        && ranges.get(&c.path).is_some_and(|(old, new)| {
            let side = if c.side == Side::Old { old } else { new };
            side.iter().any(|&(a, b)| a <= line && last <= b)
        });
    (line, last, fits)
}

/// The comment as GitHub's API takes it, on the lines `place` found.
fn inline_json(c: &ReviewComment, line: u32, last: u32) -> serde_json::Value {
    let side = if c.side == Side::Old { "LEFT" } else { "RIGHT" };
    let mut comment =
        serde_json::json!({ "path": c.path, "body": c.body, "line": last, "side": side });
    if last > line {
        comment["start_line"] = line.into();
        comment["start_side"] = side.into();
    }
    comment
}

/// POSTs `payload` to the GitHub API path with `gh`, returning the html_url
/// of what it created.
fn post(
    repo: &Path,
    host: &str,
    path: &str,
    payload: &serde_json::Value,
) -> Result<String, String> {
    let gh = gh_command();
    let mut child = Command::new(&gh)
        .current_dir(repo)
        .args([
            "api",
            "--hostname",
            host,
            "--method",
            "POST",
            path,
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
        return Err(format!(
            "{gh} api {path}: {} {}",
            String::from_utf8_lossy(&out.stderr).trim(),
            String::from_utf8_lossy(&out.stdout).trim()
        ));
    }
    #[derive(Deserialize)]
    struct Posted {
        html_url: String,
    }
    let posted: Posted =
        serde_json::from_slice(&out.stdout).map_err(|e| format!("reading {gh} output: {e}"))?;
    Ok(posted.html_url)
}

/// Removed lines are on GitHub's left side: the merge base of the pull request.
fn left_side(repo: &Path, base: Option<&str>, commit: &str) -> Result<Option<String>, String> {
    match base {
        Some(base) => Ok(Some(git::merge_base(
            repo,
            &git::commit(repo, base)?,
            commit,
        )?)),
        None => Ok(None),
    }
}

/// Submits a review to the pull request at `url`: the body and event, with
/// comments as inline comments where GitHub's diff has their lines. The
/// others are listed at the end of the body, since GitHub refuses them inline.
pub fn submit_review(review: &Submission) -> Result<Submitted, String> {
    let Submission {
        repo,
        url,
        number,
        commit,
        base,
        event,
        body,
        comments,
    } = review;
    let (repo, number, commit) = (repo.as_path(), *number, commit.as_str());
    // `gh api` goes to github.com unless told otherwise, even inside a
    // repository on GitHub Enterprise, where `gh pr view` finds the host itself.
    let (host, repository) = repository_of(url, number)?;
    let ranges = diff_ranges(repo, &host, &repository, number)?;
    let left = left_side(repo, base.as_deref(), commit)?;
    let mut inline = Vec::new();
    let mut inline_comments = Vec::new();
    let mut elsewhere = Vec::new();
    for (index, c) in comments.iter().enumerate() {
        let (line, last, fits) = place(repo, commit, left.as_deref(), c, &ranges);
        if !fits {
            let lines = if last > line {
                format!("{line}-{last}")
            } else {
                line.to_string()
            };
            let removed = if c.side == Side::Old {
                " (removed)"
            } else {
                ""
            };
            elsewhere.push(format!("- `{}` line {lines}{removed}: {}", c.path, c.body));
            continue;
        }
        inline.push(inline_json(c, line, last));
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
        payload["event"] = event.as_str().into();
    }
    let url = post(
        repo,
        &host,
        &format!("repos/{repository}/pulls/{number}/reviews"),
        &payload,
    )?;
    log(&format!(
        "submitted a review on pull request {number}: {} inline, {} in the body",
        inline.len(),
        elsewhere.len()
    ));
    Ok(Submitted {
        url,
        inline: inline.len(),
        in_body: elsewhere.len(),
        inline_comments,
    })
}

/// One comment to post at once: the `post_comment` request.
#[derive(Deserialize)]
pub struct Single {
    repo: std::path::PathBuf,
    url: String,
    number: u32,
    /// The pull request's head commit, which the comment's lines refer to.
    commit: String,
    base: Option<String>,
    comment: ReviewComment,
}

#[derive(Serialize)]
pub struct Posted {
    pub url: String,
}

/// Posts one comment on its line of the pull request at once, outside any
/// review, like GitHub's "Add single comment". GitHub takes it only on a
/// line its diff has.
pub fn post_comment(single: &Single) -> Result<Posted, String> {
    let (repo, number, commit) = (single.repo.as_path(), single.number, single.commit.as_str());
    let (host, repository) = repository_of(&single.url, number)?;
    let ranges = diff_ranges(repo, &host, &repository, number)?;
    let left = left_side(repo, single.base.as_deref(), commit)?;
    let c = &single.comment;
    let (line, last, fits) = place(repo, commit, left.as_deref(), c, &ranges);
    if !fits {
        return Err(format!(
            "{} line {line} is not in the pull request's diff on GitHub; save it for the review instead (it goes in the review's text)",
            c.path
        ));
    }
    let mut payload = inline_json(c, line, last);
    payload["commit_id"] = commit.into();
    let url = post(
        repo,
        &host,
        &format!("repos/{repository}/pulls/{number}/comments"),
        &payload,
    )?;
    log(&format!(
        "posted a comment on pull request {number}: {}:{line}",
        c.path
    ));
    Ok(Posted { url })
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

#[derive(Serialize, Deserialize)]
#[serde(rename_all(deserialize = "camelCase"))]
pub struct Listed {
    number: u32,
    title: String,
    #[serde(deserialize_with = "login")]
    author: String,
    head_ref_name: String,
    is_draft: bool,
    #[serde(default)]
    review_requested: bool,
}

/// Runs `gh pr list` in the repository with extra arguments, returning the
/// pull requests it prints.
fn gh_list(repo: &Path, extra: &[&str]) -> Result<Vec<Listed>, String> {
    let gh = gh_command();
    let mut args = vec![
        "pr",
        "list",
        "--state",
        "open",
        "--limit",
        "100",
        "--json",
        "number,title,author,headRefName,isDraft",
    ];
    args.extend_from_slice(extra);
    let out = Command::new(&gh)
        .current_dir(repo)
        .args(&args)
        .output()
        .map_err(|e| format!("running {gh}: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "{gh} pr list: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    serde_json::from_slice(&out.stdout).map_err(|e| format!("reading {gh} output: {e}"))
}

/// The repository's open pull requests, those asking for your review first.
pub fn list(repo: &Path) -> Result<Vec<Listed>, String> {
    let mut all = gh_list(repo, &[])?;
    let requested: std::collections::HashSet<u32> =
        gh_list(repo, &["--search", "review-requested:@me"])?
            .into_iter()
            .map(|pr| pr.number)
            .collect();
    for pr in &mut all {
        pr.review_requested = requested.contains(&pr.number);
    }
    all.sort_by_key(|pr| !pr.review_requested);
    log(&format!(
        "listed {} open pull requests, {} asking for your review",
        all.len(),
        requested.len()
    ));
    Ok(all)
}
