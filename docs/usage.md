# Using trail

Everything beyond the quick start in the [README](../README.md).

## Starting a review

`:Trail` alone lists the repository's open pull requests, those asking for your review first, and opens the one you pick (through `vim.ui.select`, so your picker plugin if you have one). `#123`, or the pull request's URL, reviews a GitHub pull request: `gh` finds its base and head, both are fetched, and the review runs locally like a branch. The pull request's review threads show as one line under their lines, `<CR>` opens one in a popup, and `T` lists them all, outdated ones included. `P` on the send screen submits it back as one GitHub review: an overall comment and a verdict (comment, approve, request changes, or draft for a pending review) written in a box, plus every comment not sent before, inline where GitHub's diff has the line and listed in the overall comment otherwise.

The review opens in its own tab, on the overview: the pull request's title, author and description (folded), a progress bar over every hunk, what needs your attention (unresolved threads, your blocking comments, changes no test reaches), and the paths, each one folded line with its progress and threads: `za` unfolds a path into its tree, each change under the change it is reached from, `●` reviewed and `○` not yet, and `gm` draws the map of every path through the packages they reach. The changed test files, hunks in no path and hidden files are folded below; `<CR>` opens any folded line. Working out the paths runs in the background and can take a minute on a big change.

Progress is per function: a hunk is seen once its last line has been on screen, or when you mark it with `mh`, and a function is done when all its hunks are seen, in every path that has it. Reviewed hunks show a `▎` between the gutter and the code. Review state (seen hunks, positions, comments, verdict) lives in `.git/trail/<review>.json` and survives new commits, because hunk ids hash their content and comments find their line again by its text.

`C` opens the Commits screen: the review's commits, oldest first. `<CR>` reviews just that commit, `V` and `<CR>` a run of them, and `a` all of them again; the overview and the tabline say which. Comments and reviewed hunks stay with the review whatever the range, and a pull request's comments are still submitted on their lines at its head.

Press `?` anywhere for the keys that work there.

## The trail app

`trail` also runs on its own, as Neovim with trail's own config: the path's tree on the left, the diff in the middle, threads and the comment box in a pane on the right (side by side hides the tree, leaving the call chain in the diff's winbar, and moves the pane to the bottom), the screens in the tabline and the keys in the status line. Resize the tree or the pane and it keeps that size, the pane separately at the right and at the bottom. Comments and threads don't sit between the code lines there: each shows as a mark in the gutter and a hint at the end of its line, and the pane shows the line's thread with your unsent comments and replies under it. A reply is written now and sent later. Everything you add is selected for sending (☑): `s` in the pane takes a comment out or puts it back, `e` and `d` edit and delete it, and `S` sends the selected ones as one review, replies going to their threads. Every Vim motion works, and your own config and plugins stay out. Put the engine on your `PATH` (with lazy.nvim, `ln -s ~/.local/share/nvim/lazy/trail/engine/target/release/trail ~/.local/bin/trail`), then:

```sh
trail                     # pick an open pull request
trail '#1241'             # a pull request (quoted: the shell drops a bare #1241), its URL, or main..feature
trail --my-config '#1241' # the same in your own Neovim and config
```

It takes on your Neovim's colors: at startup it asks your own Neovim, headless, for its highlight groups once your colorscheme has settled (one applied on `UIEnter`, LazyVim's `VeryLazy` or a moment later counts), your colorscheme's options and overrides included, and asks again when the app regains focus, so switching themes shows there too. It falls back to its own dark theme, with a message saying why, if that fails or takes over 3 seconds. `gd` still opens definitions in your own Neovim. `q` on the overview quits. Review state is shared with the plugin, so a review can move between the two. Inside the plugin, `vim.g.trail_tree = "left"` puts the tree on the left too.

## Keys

Paths screen

| Key | Action |
| --- | --- |
| `<CR>`, `1`–`9` | Enter a path, or on a row of its tree, enter it at that change |
| `za` | Unfold a path into its tree, or fold it |
| `gm` | Map of every path through its packages, the one under the cursor in colour |
| `r` | Resume the path last reviewed, where it was |
| `<C-p>` | Find a changed function by name and open it |
| `mr` | Mark the path as reviewed, or unmark it |
| `S` | Send screen |
| `T` | Review threads of the pull request |
| `gp` | Switch path |
| `R` | Reload |
| `q` | Quit |

Inside a path (tree on top, diff below)

| Key | Action |
| --- | --- |
| `<CR>` in the tree | Show the function on the row, or open the fold |
| `za` in the tree | Open or close what the row folds: the functions between it and its caller (`┄2`), or a reviewed branch (`✓ 6 changes`) |
| `zR` / `c` in the tree | Open everything / fold back to the changes |
| `a` in the tree | Show every function between the changes |
| `K` in the tree | Show the row's code in a popup |
| `gm` | Map of every path through its packages, this one in colour and the function shown marked `▶`; `n`/`p` colour another path, `<CR>` on a box opens the coloured path at its change there |
| `<C-p>` | Find a changed function by name and open it |
| `]s` `[s` (also `n` `p` in the tree) | Next / previous step, on its first change. `]s` follows the tree: between two branches it goes back to the function they hang from, on the line calling the next one, then into it |
| `]c` `[c` | Next / previous change of this path, across steps |
| `]h` `[h` | Next / previous hunk in the file shown |
| `]t` `[t` | Next / previous review thread of this path |
| `]]` | Follow the call on the line into the function it calls (a step, or a function on the way); off a call, move to the next one. Calls in the path show `→ name · step N` on their line, and functions `← called by …` |
| `[[` | Back to the call `]]` followed; with none, up to the line calling this function |
| `<CR>` in the diff | Open the review thread on the line in a popup |
| `r` | Reply to the review thread on the line (also in the `T` list); `<Tab>` resolves or reopens it too |
| `t` | Unified or side by side |
| `o` | On a step: fold away what is outside its function, which is otherwise shown dimmed. Elsewhere: fold unchanged code, or show the whole file |
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
| `<C-s>` | Save, in the comment box: kept for the review, sent with it |
| `<C-y>` | Post at once, in the comment box on a pull request: a comment as a single comment on its line, a reply to its thread |
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
| `vim.g.trail_fold_unchanged` | `true` | `false` to start with whole files, outside a step |
| `vim.g.trail_seen_on_scroll` | `true` | `false` to mark hunks as seen only by hand (`mh`, `mr`) |
| `vim.g.trail_default_comment_kind` | `"blocking"` | Kind `cc` starts with |
| `vim.g.trail_ignore` | `{}` | Gitignore-style patterns for files to leave out |
| `vim.g.trail_ignore_defaults` | `true` | Hide `go.sum`, `Cargo.lock`, generated Go files and the root `vendor/` and `target/` |
| `vim.g.trail_lsp` | `true` | `false` to skip `gopls` and `rust-analyzer` and match calls by name (marked `?`) |
| `vim.g.trail_engine` | | Path to the engine binary; otherwise `engine/target/release/trail`, then `debug`, then `trail` on your `PATH` |

Environment: `TRAIL_GOPLS`, `TRAIL_RUST_ANALYZER`, `TRAIL_DIFFT` and `TRAIL_GH` override the programs used; `TRAIL_LSP_TIMEOUT` (60 s, after which a language server that found nothing fails the impact), `TRAIL_IMPACT_LIMIT` (2000 functions) and `TRAIL_IMPACT_TIMEOUT` (120 s) cap the analysis.

Highlight groups: `TrailAdd`, `TrailDelete` (markers), `TrailAddText`, `TrailDeleteText` (changed tokens), `TrailContext` (unchanged text), `TrailReviewed` (the gutter mark on reviewed hunks), `TrailFiller`, `TrailBlocking`, `TrailQuestion`, `TrailNit` and their `…Block` backgrounds for saved comments.
