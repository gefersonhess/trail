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
```

`#123` reviews a GitHub pull request: `gh` finds its base and head, both are fetched, and the review runs locally like a branch.

The review opens in its own tab, on the paths screen: the paths, the changes no test reaches, the changed test files grouped by package, and hunks in no path. Working out the paths runs in the background and can take a minute on a big change.

Progress is per function: a hunk is seen once its last line has been on screen, and a function is done when all its hunks are seen, in every path that has it. Review state (seen hunks, positions, comments, verdict) lives in `.git/trail/<review>.json` and survives new commits, because hunk ids hash their content and comments find their line again by its text.

Press `?` anywhere for the keys that work there.

## Keys

Paths screen

| Key | Action |
| --- | --- |
| `<CR>`, `1`–`9` | Enter a path |
| `mr` | Mark the path as reviewed, or unmark it |
| `S` | Send screen |
| `gp` | Switch path |
| `R` | Reload |
| `q` | Quit |

Inside a path (tree on top, diff below)

| Key | Action |
| --- | --- |
| `]s` `[s` (`n` `p` in the tree) | Next / previous step |
| `]c` `[c` | Next / previous change of this path, across steps |
| `]h` `[h` | Next / previous hunk in the file shown |
| `<CR>` in the tree | Open a fold, show a step or function |
| `a` / `c` in the tree | Show every function on the way / fold back to the changes |
| `t` | Unified or side by side |
| `o` | Fold unchanged code, or show the whole file |
| `K` | Show the function's code in a popup |
| `gd` | Open the definition in a separate Neovim with your config |
| `mr` | Mark the path as reviewed |
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
| `<CR>` | Go to the comment |
| `d` | Delete the comment |

## Configuration

| Setting | Default | Effect |
| --- | --- | --- |
| `vim.g.trail_layout` | `"unified"` | `"side_by_side"` to start side by side |
| `vim.g.trail_fold_unchanged` | `true` | `false` to start with whole files |
| `vim.g.trail_default_comment_kind` | `"blocking"` | Kind `cc` starts with |
| `vim.g.trail_ignore` | `{}` | Gitignore-style patterns for files to leave out |
| `vim.g.trail_ignore_defaults` | `true` | Hide `go.sum`, `Cargo.lock`, generated Go files and the root `vendor/` and `target/` |
| `vim.g.trail_engine` | | Path to the engine binary |

Environment: `TRAIL_GOPLS`, `TRAIL_RUST_ANALYZER`, `TRAIL_DIFFT` and `TRAIL_GH` override the programs used; `TRAIL_LSP_TIMEOUT` (60 s), `TRAIL_IMPACT_LIMIT` (2000 functions) and `TRAIL_IMPACT_TIMEOUT` (120 s) cap the analysis.

Highlight groups: `TrailAdd`, `TrailDelete` (markers), `TrailAddText`, `TrailDeleteText` (changed tokens), `TrailContext` (unchanged text), `TrailFiller`, `TrailBlocking`, `TrailQuestion`, `TrailNit` and their `…Block` backgrounds for saved comments.

## Development

```sh
cd engine && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
nvim --headless -u NONE -l test/plugin.lua   # needs a built engine and difft
```

The engine, `trail serve`, speaks JSON-RPC 2.0 over stdio, one message per line, logging to stderr. Methods: `open` (files, hunks, nodes, call edges), `impact` (paths), `file_diff` (aligned rows and changed tokens for one file), `peek` (find a function by name), `checkout` (a worktree at a commit) and `pull_request`. What `open` and `impact` return is described in [docs/design.md](docs/design.md).
