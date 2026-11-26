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

- A list of paths, one folded line each: its name, done/total and threads. `za` unfolds a path into its tree (below); the path last reviewed starts unfolded, with `▶` where the review was, and `r` resumes there. `gm` opens the map.
- "No test reaches": the changes no test calls, even through other code.
- The changed test files, with the functions they cover.
- A "Not in any path" section. Every changed hunk lands in a path, in Tests, or here.
- `<CR>` or a number enters a path. `<C-p>` finds a changed function by fuzzy name. `S` opens the send screen.

### Inside a path

- The path's tree on top (or on the left): one tree per entry point, each change under the change it is reached from, in the order `]s` walks them. Each row has a mark (`▶` shown now, `●` reviewed, `○` not yet, `◇` unchanged), the name coloured by the kind of change, and its thread count on the right. Unchanged functions between two changes are drawn in the connector (`├┄● Store.Save  ┄2`); `za` opens them into rows, `a` opens all of them. A change reached again shows again under each caller, with the changes below it (more than 5 fold into `▸ N changes`); those rows are never steps. A branch whose changes are all reviewed folds to one row (`✓ 6 changes`); `za` opens it, `zR` opens everything and `c` folds back. The cursor row shows its step, interface, tests and package at its end. `<CR>` shows the row's function, and `]s`/`[s` move the cursor with the step. At most a third of the screen, scrolled to the current row.
- The diff's winbar shows where the function shown sits: the route from an entry point down to it (`Handler › Service.Create › ▶Store.Save`), unchanged functions on the way included, and `+N callers` when other functions of the path call it too. While its first line is scrolled off, that line stays pinned at the top of the diff.
- `gm` opens the map: a floating window with the review's packages as boxes, callers above what they call, and every path as a numbered route (①, ②) through the packages it reaches. Only the selected path is in colour, the function shown is marked `▶`, and a call to a package already drawn elsewhere is listed in its caller's box (`→ store ②`). `n`/`p` select another path; `<CR>` on a box opens the selected path at its first change in that package.
- Test files and hunks in no path show as a list.
- A scrollable diff below, unified by default and side by side with `t`, with unchanged stretches folded.
- `]s`/`[s` in the diff (or `n`/`p` in the graph) move between steps, `]h`/`[h` between hunks, `-` goes back to the paths screen. `]s` follows the tree: between two branches it stops at the row they hang from, on the line calling the next one, before going into it. A step opens on its function's first change. The diff marks the line `]s`, `[s`, `]c` and `[c` would land on (`◂ ]s` at its end, pinned to the window's edge when out of view, or next to the fold when folded away), with the call underlined when `]s` stops on a caller's line, and the calls `]]` can follow marked on the cursor's line (`]]` the first, `2]]` the second).
- `<CR>` on a node in the graph jumps the diff to it.
- `K` shows a function's code in a popup. `gd` opens it in a separate Neovim in a floating terminal, with the user's own config and LSP.

### Navigation and progress

- Paths can be visited in any order.
- Progress is tracked per node, not per path. A node reviewed in one path shows as done in every path that contains it.
- A step is done only after all of its hunks have been scrolled past or marked by hand (`mh` on a hunk, `mr` on a path).
- Each path remembers its step and scroll position.
- A path switcher opens from anywhere.

### Tests

- Tests never start a tree. They are detected by path patterns (`*_test.go`, `tests/`, and so on), configurable, and show as a count on the rows they call.
- Each changed test file is listed with the code it covers.
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

The engine runs as a long-lived process (`trail serve`) that the plugin talks to over JSON-RPC on stdio. The engine owns the language servers (gopls, rust-analyzer) for the review worktree. There is one language server per worktree, and a future TUI or web view can reuse the engine unchanged.

### Engine output

Derived data, recomputable from git and the code at any time:

- `files`: path, status, language, whether it is a test.
- `hunks`: id, file, old and new line ranges, `moved_from`.
- `nodes`: id (language plus qualified name, e.g. `go:auth.VerifyHash`), kind, status (added, modified, removed, context), old and new ranges, hunk ids, whether it is a test.
- `edges`: from, to, status (added, removed, unchanged), source (`lsp` or `name_match`, the latter shown as uncertain).
- `paths`: id, title, origin (`graph` or `ai`), steps. A step is a list of nodes, so related changes can be shown together.
- `tests`: test file and the nodes it covers.
- `unassigned`: hunks in no path and not in tests.

`impact` is a separate, slower method that walks from each changed function up to the entry points and down through what it calls, unchanged code included, and returns one path per group of changes that reach each other: its nodes (with `entry` and `is_test`), its edges (with `via` for calls through an interface or trait), `trees` laying the path out from each entry point down (rows with depth, `via`, and `join` where a row was already shown), the changed functions as steps in that order, and `truncated` when the node or time limit (`TRAIL_IMPACT_LIMIT`, `TRAIL_IMPACT_TIMEOUT`) cut it short. It uses the language server unless `lsp` is `false`; `open` uses it only when `lsp` is `true`.

### Review state

The user's own data, stored separately under `.git/trail/<review>.json` and never recomputed: seen hunks, position per path, comments, reviewer session id.

### Stable ids

Hunk ids are hashes of the file and the changed content, not line numbers. When the author pushes new commits, hunks they did not touch keep their ids and stay reviewed, and changed ones show up as unreviewed. Comments store the line text so they can find their line again after it moves.

## First version

In:

- `:Trail main..branch` and `:Trail #123` (GitHub PR via `gh`).
- Changed symbols from git diff and tree-sitter, for Go and Rust.
- Call edges from the LSP call hierarchy.
- Paths built without AI: the impact of each change, walked through the call hierarchy up to its entry points and down through its calls (see `decisions.md`). Tests separated.
- Paths screen and path view.
- The difftastic diff: the engine runs `difft` (JSON output) on both versions of a file, and the plugin draws its line alignment and changed tokens in its own buffers, so comments and navigation work on them. Without `difft`, a line diff with whitespace ignored. Moved code is not marked yet.
- Comments and per-node progress, saved under `.git/`.
- Copy comments as markdown.

Later:

- AI reviewer, AI-proposed paths, the ask flow.
- Sending comments to an agent or posting them to GitHub.
- Collapsed view for big changes.
- Structural diff with moved-code detection.

## Paths without AI

One path per group of changed functions connected by calls or uses, removed calls included, ignoring tests. A path starts at its entry points (changed functions nothing else in the group calls) and its steps follow calls depth-first, so a caller is read before what it calls. Larger paths come first. Changed types and constants are nodes too, and unchanged functions that use them join as context nodes, so a type change appears in the path of the code using it. Test files are grouped separately with the changed functions they reach; hunks outside any function and test file are listed as not in any path.
