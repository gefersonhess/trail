# trail design

## Problem

Line-based review tools show a change file by file. That hides how the changes connect: which changed function calls which, where a new function is used, which unchanged code now receives different input. Git diffs also add noise: formatting changes, moved code shown as delete plus add, small edits inside a line, and no surrounding function context.

## Priorities

1. A better diff view.
2. Code navigation (definitions, callers, callees).
3. A guided review that follows calls instead of files.
4. AI integration.

## Screens

Two levels, like a file explorer.

### Paths screen (home)

- A list of paths. Each path is a thread of related changes with its step count and progress.
- A Tests section after the code paths.
- A "Not in any path" section. Every changed hunk lands in a path, in Tests, or here.
- A preview of the selected path's call graph below the list.
- `<CR>` or a number enters a path. `S` opens the send screen.

### Inside a path

- The path's call graph (DAG) on top, current step highlighted, at most a third of the screen and scrollable beyond that.
- A scrollable side-by-side diff below, with unchanged stretches folded.
- `n`/`p` move between steps, `]h` between hunks, `-` goes back to the paths screen.
- `<CR>` on a node in the graph jumps the diff to it.
- `gd` uses the LSP on the new side.

### Navigation and progress

- Paths can be visited in any order.
- Progress is tracked per node, not per path. A node reviewed in one path shows as done in every path that contains it.
- A step is done only after all of its hunks have been scrolled past.
- Each path remembers its step and scroll position.
- A path switcher opens from anywhere.

### Tests

- Test files never appear in code paths. They are detected by path patterns (`*_test.go`, `tests/`, and so on), configurable.
- Each test file is linked to the code it covers, through the call graph.
- Changed functions that no test change covers are listed as warnings.

### Comments and sending

- Comments attach to a line in a node and show as virtual text.
- Each comment has a kind: blocking, question or nit.
- The send screen lists comments grouped by file, a verdict, and a warning for hunks never scrolled past.
- `y` copies the review as markdown. `s` sends it to an agent session (later).

### Big changes

- When the graph does not fit, it starts collapsed by directory with call counts between groups, expanded one group at a time (later).

## AI reviewer (later)

- One fresh agent session per review, never the session that wrote the code.
- The same session proposes the paths and answers every question during the review, so later questions build on earlier ones.
- The session is saved with the review and resumed when the review is reopened.
- Supports Claude Code (`claude -p` with stream-json and session resume) and pi (RPC mode over JSON lines, sessions by id), behind one small adapter.
- The reviewer runs in its own git worktree at the change's head, so it cannot edit your working copy.
- Asking (`a`) works on a node, a line or a selection. Context (diff, callers, callees, path) is attached automatically and can be edited.
- Answers appear in a split under the diff. References are jumpable. Nodes with a thread get a `?` badge.
- `C` drafts a comment from an answer. Answers never enter the review unless turned into comments.

## How the graph is built

- Opening a GitHub PR uses GitHub only to find the base and head commits and fetch them. The diff is computed locally between the merge base and the head, so local branches and PRs take the same path.
- The head is checked out in a separate worktree. One review worktree per repository is reused across reviews so build caches and the language server index stay warm.
- Tree-sitter finds the changed functions from the diff's line ranges.
- Call edges come from the LSP's call hierarchy (gopls, rust-analyzer) run in the head worktree. Positions line up with the new side of the diff.
- Removed-call edges come from tree-sitter name matching on the old side, which has no LSP.
- The screens appear before the LSP is ready, with name-matched edges shown as uncertain until the LSP confirms them.

## Architecture

trail has two parts:

- The engine, a Rust binary, does all the analysis: reading the diff, finding changed functions with tree-sitter, building call edges, forming paths, and checking that every hunk is covered.
- The Neovim plugin draws the screens and keeps the review state. It asks the engine for results.

The engine runs as a long-lived process (`trail serve`) that the plugin talks to over JSON-RPC on stdio. The engine owns the language servers (gopls, rust-analyzer) for the review worktree. The same language server builds the call edges and answers `gd` during the review, so there is one instance per worktree, and a future TUI or web view can reuse the engine unchanged.

### Engine output

Derived data, recomputable from git and the code at any time:

- `files`: path, status, language, whether it is a test.
- `hunks`: id, file, old and new line ranges, `moved_from`.
- `nodes`: id (language plus qualified name, e.g. `go:auth.VerifyHash`), kind, status (added, modified, removed, context), old and new ranges, hunk ids, whether it is a test.
- `edges`: from, to, status (added, removed, unchanged), source (`lsp` or `name_match`, the latter shown as uncertain).
- `paths`: id, title, origin (`graph` or `ai`), steps. A step is a list of nodes, so related changes can be shown together.
- `tests`: test file and the nodes it covers.
- `unassigned`: hunks in no path and not in tests.

### Review state

The user's own data, stored separately under `.git/trail/<review>.json` and never recomputed: seen hunks, position per path, comments, reviewer session id.

### Stable ids

Hunk ids are hashes of the file and the changed content, not line numbers. When the author pushes new commits, hunks they did not touch keep their ids and stay reviewed, and changed ones show up as unreviewed. Comments store the line text so they can find their line again after it moves.

## First version

In:

- `:Trail main..branch` and `:Trail #123` (GitHub PR via `gh`).
- Changed symbols from git diff and tree-sitter, for Go and Rust.
- Call edges from the LSP call hierarchy.
- Paths built from the graph without AI: one path per connected group of changed functions, starting at its entry point. Tests separated.
- Paths screen and path view.
- The difftastic diff: the engine runs `difft` (JSON output) on both versions of a file, and the plugin draws its line alignment and changed tokens in its own side-by-side buffers, so comments and navigation work on them. Without `difft`, a line diff with whitespace ignored. Moved code is not marked yet.
- Comments and per-node progress, saved under `.git/`.
- Copy comments as markdown.

Later:

- AI reviewer, AI-proposed paths, the ask flow.
- Sending comments to an agent or posting them to GitHub.
- Collapsed view for big changes.
- Structural diff with moved-code detection.

## Open questions

- How paths are formed without AI, in detail.
