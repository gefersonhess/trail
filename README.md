# trail

Review code changes inside Neovim by their impact: what reaches each change and what it calls, instead of a list of files.

trail splits a change into paths: each starts at the entry points that reach a change, such as a route, a CLI command or a public function, and follows the calls down through it, unchanged code included. You open a path, see it as a tree on top and the diff below, and step through its changes. Comments are collected as you go and copied out at the end.

Status: design. See [docs/design.md](docs/design.md).

Languages: Go and Rust first.

## Trying it in Neovim

Requires Neovim 0.10 or later, a Rust toolchain, and [difftastic](https://difftastic.wilfred.me.uk/) (`difft`) on your `PATH` for the structural diff. Without `difft` the diff falls back to a plain line diff. With lazy.nvim:

```lua
{
  "gefersonhess/trail",
  build = "cd engine && cargo build --release",
  cmd = "Trail",
}
```

Or point `dir` at a local checkout and build the engine yourself. The plugin uses `engine/target/release/trail` (or `debug`), then `trail` on your `PATH`. Set `vim.g.trail_engine` to use another binary.

In a Go or Rust repo:

```
:Trail main..my-branch
:Trail #123
```

`#123` reviews a GitHub pull request: `gh` finds its base branch and head, both are fetched from the pull request's repository into `refs/trail/pull/123/`, and the review runs locally like any branch. Its review state is kept per pull request number, so progress and comments survive new pushes.

A tab opens on the paths screen. The whole review stays in that tab: entering a path, going back with `-` and the send screen all replace what the tab shows instead of opening new tabs. Each path is a change and everything that can reach it or that it calls, walked through the language server's call hierarchy (or by name without one); changes that reach each other share a path. Each row shows the path's first change, how many changes it has, how far it reaches, your progress and the packages it touches. Below come the changes no test reaches, the changed test files, then the hunks that are in no path. A preview of the selected path sits at the bottom. Working out the paths runs in the background, which can take a minute on a big change. `<CR>` or `1`–`9` enters a path, `gp` switches to another path from anywhere, `R` reloads, `q` quits. In the list and in diffs, `?` shows the keys that work there.

Calls between changed functions are first matched by name with tree-sitter, so the screen appears at once; those are marked `?`. Trail then asks the language server (`gopls`, or `rust-analyzer`; override with `TRAIL_GOPLS` and `TRAIL_RUST_ANALYZER`) for its call hierarchy in a checkout of the head, replaces the matched calls with the confirmed ones, and redraws. Removed calls stay name-matched, since the old code has no language server. Without a server, or if it fails or takes longer than `TRAIL_LSP_TIMEOUT` seconds (60), the matched calls stay. `vim.g.trail_lsp = false` turns this off.

Inside a path, its tree sits on top (at most a third of the screen) with the current step marked, and the diff of that step below. By default the tree shows only the entry points and the path's changes, each under the change it is reached from, with short names and the package in a column on the right; a `▸ N functions` line stands for the unchanged functions a call goes through, and entry points that only join a tree shown above are folded into one line. `a` switches to every function on the way, stopping at the last change, with what leads to no change folded into `▸ N more` lines. In the tree, `<CR>` opens a fold or a link, shows a step, or shows an unchanged function in its file below; `c` folds everything back to the changes; `K` shows a function's code; `n` and `p` move between steps. In the diff, `]s` and `[s` move between steps (`n` stays search-next there). `-` goes back to the paths screen.

Progress is tracked per function: a hunk counts as seen once its last line has been on screen, and a function is done when all its hunks are seen, in every path that contains it. The paths screen shows done/total per path, finished steps get a `✓` in the tree, and each path reopens at the step you left it on. In a diff, `cb`, `cq` and `cn` add a blocking, question or nit comment on the line under the cursor (either side), shown as virtual lines under it in both layouts; `ce` edits and `cd` deletes the comment on the line. Comments keep their line's text, so after new commits they move with their line. `S` on the paths screen opens the send screen: comments grouped by file, a verdict (`v` cycles approve, request changes, comment), and a warning listing hunks not seen yet. `y` there copies the review as markdown, `<CR>` jumps to a comment's step, `d` deletes a comment.

This review state, comments and verdict included, lives in `.git/trail/<base..head>.json`; hunk ids hash their content, so it survives new commits to the branch.

Diffs are unified by default: one column with old and new line numbers in the gutter, and each changed block shown as its old lines (`-`) followed by its new lines (`+`). `t` switches to side by side, where lines are aligned the way difftastic aligns them with filler where one side has no matching line, and back again. The cursor stays on the same line of code, and the layout you switch to is kept for the next file. Set `vim.g.trail_layout = "side_by_side"` to start with side by side.

To leave files out of a review, set `vim.g.trail_ignore` to a list of gitignore-style patterns, for example `{ "*.pb.go", "go.sum", "vendor/" }`. A pattern without a slash matches a file name anywhere, a leading `/` anchors it to the repository root, and a trailing `/` matches a whole folder. Ignored files get no diff, nodes, call edges or paths, and the paths screen says how many are hidden.

In both layouts only the tokens that actually changed are highlighted, so formatting changes don't show up, and reformatted code appears once as plain context. Long unchanged stretches are folded; `o` shows the whole file instead, or folds it again, and that choice is also kept for the next file (`vim.g.trail_fold_unchanged = false` starts with the whole file shown). `]h` and `[h` move hunk by hunk either way, `-` goes back to the list. `K` on a function or method name opens a popup with its code, like LSP hover but found with `git grep` and tree-sitter: the version at base on a removed line, at head anywhere else, preferring the package or type written before the name, then the same file, then the same directory. The title marks functions that are part of the review. Press `K` again to move into the popup and scroll; moving the cursor closes it. `gd`, or `<CR>` inside the popup, opens the definition in a separate Neovim inside a large floating terminal. It starts with your own config, so your LSP setup, pickers and jumps (`gd`, `gr`, hover) work as in any session and can't touch the review. Quitting it closes the window and returns to the diff. Head versions open from your checkout when it is at the review's head commit, otherwise from a review worktree under `~/.cache/trail/worktrees` that trail moves to the head and reuses (edits there are discarded). Base versions, on removed lines, open read-only in a floating window without LSP. `:q` closes the window. Colors come from highlight groups you can override: `TrailAdd` and `TrailDelete` for the markers, `TrailAddText` and `TrailDeleteText` for changed tokens, `TrailFiller` for filler rows.

Run the plugin's test with `nvim --headless -u NONE -l test/plugin.lua`.

## Engine

```sh
cd engine && cargo build
./target/debug/trail serve
```

`trail serve` reads JSON-RPC 2.0 requests from stdin, one per line, and writes one response per line to stdout. Logs go to stderr. It exits when stdin closes.

```json
{"jsonrpc":"2.0","id":1,"method":"open","params":{"repo":"/path/to/repo","base":"main","head":"feature"}}
```

`open` (with `"lsp": true` to confirm calls with the language server, answered on its own thread) diffs `head` against its merge base with `base`, ignoring whitespace. For modified Go and Rust files it also asks difftastic, and drops hunks that only reformat code, so a function whose only change is formatting is not listed. Without `difft`, git's whitespace-ignoring diff decides. It returns:

- `base_commit` and `head_commit`: the merge base and head that were compared.
- `files`: path, status, language, whether it is a test.
- `hunks`: id, file, old and new line ranges. Ids hash the file and changed lines, so they stay the same when other hunks shift.
- `nodes`: the Go and Rust functions and methods a hunk touches, found with tree-sitter. Each has an id such as `go:auth.Store.Save` or `rust:auth::hash::verify`, a status (added, modified, removed), old and new ranges, and the ids of its hunks.
- `edges`: calls between changed nodes, as `from`, `to` and a status: `added` (call only in the new code), `removed` (only in the old code) or `unchanged`. They are matched by name with tree-sitter, so their `source` is `name_match` and they should be shown as uncertain. A call matches by how it is written: `a::f()` only a function under `a`, `x.f()` only methods (or, in Go, a function in package `x`), and a bare `f()` only functions, in the same package for Go. Production code never links to test-only functions.

`file_diff` takes `repo`, `base_commit`, `head_commit` and the file's `old_path` and `new_path` (leave one out for an added or deleted file). It returns both versions' lines, `rows` pairing old and new line numbers (`null` for filler), and `old_changes` and `new_changes`: each changed line with the byte ranges of its changed tokens. `engine` says whether difftastic (`difft`, or `TRAIL_DIFFT`) produced it or the plain line diff fallback did.

`peek` takes `repo`, `commit`, `language` (`go` or `rust`), `name`, an optional `qualifier` and `from_path`, and returns the functions and methods with that name at that commit, best match first, each with its path, qualified name, kind, line range and lines.

`impact` takes the same `repo`, `base` and `head` as `open` and returns `paths`: each changed function (and changed type or constant, through the functions using it) walked up to its entry points and down through what it calls, unchanged code included, with the language server's call hierarchy when one answers and by name otherwise. Each path has its `nodes` (with `package`, `short`, `entry` and `is_test`), its `edges` (with `via` for calls through an interface or trait), its `steps` and `trees` laying it out from each entry point down. `TRAIL_IMPACT_LIMIT` (2000 functions) and `TRAIL_IMPACT_TIMEOUT` (120 seconds) cap the walk, and `truncated` says when one did.

`checkout` takes `repo` and `commit` and returns `path`, a directory with that commit checked out, and `worktree`, which is false when that is the repository itself.

`pull_request` takes `repo` and `number`, runs `gh pr view` (or `TRAIL_GH`), fetches the pull request's head and base branch, and returns `number`, `title`, `url`, `base` and `head` commits.
