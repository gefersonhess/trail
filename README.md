# trail

Review code changes in Neovim by what they affect, not file by file.

trail groups a change into paths. A path starts at the entry points that reach a change (a route, a CLI command, a public function) and follows the calls down through it, unchanged code included. You open a path, see it as a tree with the diff below, and step through its changes, leaving comments as you go.

Early work, for Go and Rust. How it works: [docs/design.md](docs/design.md). Why it works that way: [docs/decisions.md](docs/decisions.md).

## Requirements

- Neovim 0.10 or later
- A Rust toolchain, to build the engine
- [difftastic](https://difftastic.wilfred.me.uk/) (`difft`) for the token diff; without it trail uses a plain line diff
- Optional: `gopls` or `rust-analyzer` for exact call edges (otherwise calls are matched by name and marked `?`), and `gh` for pull requests

## Install

With lazy.nvim:

```lua
{
  "gefersonhess/trail",
  build = "cd engine && cargo build --release",
  cmd = "Trail",
}
```

The plugin looks for `engine/target/release/trail`, then `debug`, then `trail` on your `PATH`. Set `vim.g.trail_engine` to use another binary.

## Usage

```
:Trail main..my-branch
:Trail #123
:Trail
```

`:Trail` alone lists the repository's open pull requests, those asking for your review first, and opens the one you pick (through `vim.ui.select`, so your picker plugin if you have one). `#123`, or the pull request's URL, reviews a GitHub pull request: `gh` finds its base and head, both are fetched, and the review runs locally like a branch. The pull request's review threads show as one line under their lines, `<CR>` opens one in a popup, and `T` lists them all, outdated ones included. `P` on the send screen submits it back as one GitHub review: an overall comment and a verdict (comment, approve, request changes, or draft for a pending review) written in a box, plus every comment not sent before, inline where GitHub's diff has the line and listed in the overall comment otherwise.

The review opens in its own tab, on the overview: the pull request's title, author and description (folded), a progress bar over every hunk, what needs your attention (unresolved threads, your blocking comments, changes no test reaches), and the paths with their progress. The changed test files, hunks in no path and hidden files are folded below; `<CR>` opens any folded line. Working out the paths runs in the background and can take a minute on a big change.

Progress is per function: a hunk is seen once its last line has been on screen, or when you mark it with `mh`, and a function is done when all its hunks are seen, in every path that has it. Reviewed hunks show a `▎` between the gutter and the code. Review state (seen hunks, positions, comments, verdict) lives in `.git/trail/<review>.json` and survives new commits, because hunk ids hash their content and comments find their line again by its text.

Press `?` anywhere for the keys that work there.

## The trail app

`trail` also runs on its own, as Neovim with trail's own config: the tree on the left, the diff in the middle, threads and the comment box in a pane on the right (side by side moves the tree to the top and the pane to the bottom), the screens in the tabline and the keys in the status line. Every Vim motion works, and your own config and plugins stay out. Put the engine on your `PATH` (with lazy.nvim, `ln -s ~/.local/share/nvim/lazy/trail/engine/target/release/trail ~/.local/bin/trail`), then:

```sh
trail                 # pick an open pull request
trail #1241           # a pull request, its URL, or main..feature
trail --my-config #1241   # the same in your own Neovim and config
```

`gd` still opens definitions in your own Neovim. `q` on the overview quits. Review state is shared with the plugin, so a review can move between the two. Inside the plugin, `vim.g.trail_tree = "left"` puts the tree on the left too.

## Keys

Paths screen

| Key | Action |
| --- | --- |
| `<CR>`, `1`–`9` | Enter a path |
| `mr` | Mark the path as reviewed, or unmark it |
| `S` | Send screen |
| `T` | Review threads of the pull request |
| `gp` | Switch path |
| `R` | Reload |
| `q` | Quit |

Inside a path (tree on top, diff below)

| Key | Action |
| --- | --- |
| `]s` `[s` (`n` `p` in the tree) | Next / previous step |
| `]c` `[c` | Next / previous change of this path, across steps |
| `]h` `[h` | Next / previous hunk in the file shown |
| `]t` `[t` | Next / previous review thread of this path |
| `<CR>` in the diff | Open the review thread on the line in a popup |
| `r` | Reply to the review thread on the line (also in the `T` list); `<Tab>` resolves or reopens it too |
| `<CR>` in the tree | Open a fold, show a step or function |
| `a` / `c` in the tree | Show every function on the way / fold back to the changes |
| `t` | Unified or side by side |
| `o` | Fold unchanged code, or show the whole file |
| `K` | Show the function's code in a popup |
| `gd` | Open the definition in a separate Neovim with your config |
| `mr` | Mark the path as reviewed |
| `mh` | Mark the hunk under the cursor (or the selected hunks) as reviewed, or unmark it |
| `-` | Back to the paths screen |

Comments, in a diff

| Key | Action |
| --- | --- |
| `cc` | Comment on the line, or on the visual selection |
| `cb` `cq` `cn` | Same, as blocking, question or nit |
| `ce` / `cd` | Edit / delete the comment on the line |
| `<C-s>` | Save, in the comment box |
| `<Tab>` (`<C-t>` while typing) | Change the kind, in the comment box |
| `q` `<Esc>` | Cancel, in the comment box |

Send screen

| Key | Action |
| --- | --- |
| `v` | Change the verdict |
| `y` | Copy the review as markdown |
| `P` | Submit the review to the pull request (only for `:Trail #123`) |
| `<CR>` | Go to the comment |
| `d` | Delete the comment |

## Configuration

| Setting | Default | Effect |
| --- | --- | --- |
| `vim.g.trail_layout` | `"unified"` | `"side_by_side"` to start side by side |
| `vim.g.trail_fold_unchanged` | `true` | `false` to start with whole files |
| `vim.g.trail_seen_on_scroll` | `true` | `false` to mark hunks as seen only by hand (`mh`, `mr`) |
| `vim.g.trail_default_comment_kind` | `"blocking"` | Kind `cc` starts with |
| `vim.g.trail_ignore` | `{}` | Gitignore-style patterns for files to leave out |
| `vim.g.trail_ignore_defaults` | `true` | Hide `go.sum`, `Cargo.lock`, generated Go files and the root `vendor/` and `target/` |
| `vim.g.trail_lsp` | `true` | `false` to skip `gopls` and `rust-analyzer` and match calls by name (marked `?`) |
| `vim.g.trail_engine` | | Path to the engine binary |

Environment: `TRAIL_GOPLS`, `TRAIL_RUST_ANALYZER`, `TRAIL_DIFFT` and `TRAIL_GH` override the programs used; `TRAIL_LSP_TIMEOUT` (60 s), `TRAIL_IMPACT_LIMIT` (2000 functions) and `TRAIL_IMPACT_TIMEOUT` (120 s) cap the analysis.

Highlight groups: `TrailAdd`, `TrailDelete` (markers), `TrailAddText`, `TrailDeleteText` (changed tokens), `TrailContext` (unchanged text), `TrailReviewed` (the gutter mark on reviewed hunks), `TrailFiller`, `TrailBlocking`, `TrailQuestion`, `TrailNit` and their `…Block` backgrounds for saved comments.

## Development

```sh
cd engine && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
nvim --headless -u NONE -l test/plugin.lua   # needs a built engine and difft
```

The engine, `trail serve`, speaks JSON-RPC 2.0 over stdio, one message per line, logging to stderr. Methods: `open` (files, hunks, nodes, call edges), `impact` (paths), `file_diff` (aligned rows and changed tokens for one file), `peek` (find a function by name), `checkout` (a worktree at a commit) and `pull_request`. What `open` and `impact` return is described in [docs/design.md](docs/design.md).
