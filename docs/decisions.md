# Decisions

What was decided while building trail, and why. `design.md` describes how trail works; this file records the choices behind it, so they aren't reopened by accident. Add to it when a decision changes.

## Product

- **Goal:** replace plannotator and tuicr for reviewing git changes. In order of importance: a better diff, code navigation, a guided review that follows calls instead of files, then AI integration.
- **Frontend:** a Neovim plugin. A standalone TUI that opens Neovim on demand was considered after definition navigation clashed with a user's Neovim config. Opening definitions in a separate Neovim (below) solved that, so the plugin stays. The engine knows nothing about Neovim, so a TUI can still be added later as another client.
- **Review flow:** two levels. A paths screen lists the paths, test files and hunks in no path; entering a path shows its call graph on top and the diff below. Paths can be visited in any order, and progress is tracked per hunk, so work done in one path counts in every path.
- **Paths show the impact of a change (replacing connected groups):** a path starts at a changed function and shows everything that can reach it, up to the entry points (functions nothing in the repository calls), and everything it calls, through unchanged code. The first version only connected changed functions to each other, so a change reached through an unchanged function (`Handler` → `Service.Create` → `Store.Save`) split into separate paths and the reach of a change was invisible.
  - **Overlapping changes share a path:** when one changed function's impact reaches another changed function, they become one path. Separate paths per change would multiply on big PRs.
  - **The engine works out everything, the screen shows a little:** the walk goes all the way up and down, capped by a node limit and a time limit. The view opens a couple of levels deep and the reviewer expands further.
  - **A path reads from beginning to end.** It is laid out as one tree per entry point going down through the calls, not centered on the change. The tree through most changes comes first; each later tree stops where it reaches something already shown ("joins"), and still shows any change of its own before that point. Trees that only join are folded on big paths.
  - **Steps are the path's changed functions, in the order the trees show them.** Unchanged functions are reached by moving through the tree, with `K` to see their code. A change that belongs to another path shows as changed without being a step.
  - **AI-proposed paths come later,** on top of this graph rather than instead of it.
- **Tests stay out of code paths:** they get their own section, listing the changed functions each test file reaches and the ones no test change covers.
- **Comments:** kinds are blocking, question and nit. For now the review is copied as markdown and pasted into an agent conversation. Sending to an agent or posting to GitHub comes later.
- **AI reviewer (later):** a fresh agent session per review, never the one that wrote the code, reused for every question in that review. It must support Claude Code and pi.

## Diff

- **difftastic, drawn by trail:** the engine runs `difft --display json` and the plugin draws the result in its own buffers. Comments on lines are essential, so difftastic's read-only terminal output was not an option. Without `difft`, a line diff with whitespace ignored is used.
- **What counts as changed:** difftastic decides. Hunks that are only formatting are dropped from the review.
- **Markers, not tinted lines:** changed lines get a `+` or `-` in the gutter, and only the changed tokens are highlighted.
- **Unified by default:** `t` switches to side by side and `o` toggles between folded and whole-file views. Both choices carry over to the next file.

## Navigation

- **`K` without an LSP:** the popup finds a definition with tree-sitter and `git grep`, at base on removed lines and at head elsewhere, so it works without a language server.
- **`gd` opens a separate Neovim:** the definition opens in a fresh `nvim` inside a large floating terminal, at the line, with the user's own config. `:q` returns to the diff. Two earlier attempts failed:
  - A floating buffer in the review's Neovim: pickers behind `gr` jump into a normal window, which was the review.
  - A tab per definition (#7): tabs piled up and jumps still depended on the user's config.

  The separate Neovim runs without `$NVIM`, so plugins that hand files to a parent Neovim leave the review alone. It also maps `<Esc>` in the terminal buffer, so a global "leave terminal mode" mapping doesn't swallow it, and skips swap files. Removed lines still open read-only in a float, since there is no file to edit.
- **One review tab:** the paths screen, a path and the send screen take turns in a single tab. Going back cancels any diff still loading for that window.

## Engine

- **Rust, JSON-RPC over stdio:** a long-lived `trail serve` process, so the plugin stays thin and other clients can reuse it.
- **The impact walk uses the language server's call hierarchy.** Tested on a small Go module with gopls: incoming calls on a concrete method include callers that only go through an interface or a method value, and with two implementations each gets only the calls that could reach it. Outgoing calls stop at the interface method, so the walk asks for its implementations to continue down. Whether a caller goes through an interface comes from asking for the definition at the call site. Without a language server the walk matches calls by name with tree-sitter and marks them uncertain; on chi that was slower (67 s against 38 s) and joined unrelated changes through every `ServeHTTP` and `String` method, so the language server is the real path and names only a fallback.
  - **Interfaces from outside the repository don't join paths.** Calls through `io.Writer` or `http.Handler` are shown, labeled with the interface, but they connect nearly everything in an HTTP codebase. The repository's own interfaces do join paths, since services usually call their stores through one.
  - **Entry points are functions nothing outside test files calls**, so a library's public API counts. A function literal is named after the function holding it, and the walk continues up through that function instead of stopping at the literal.
  - **A changed file the build leaves out** (a `//go:build` line) is skipped by the language server instead of sending the whole language to name matching.
- **The engine owns the language servers** (gopls, rust-analyzer) and runs them in the review worktree. Calls found by name matching show at once as uncertain (`?`). The language server confirms them in the background, and the screens update when it does.
- **Go and Rust first.**
- **Stable ids:** hunk ids hash the file and the changed lines, not line numbers, so reviewed hunks stay reviewed when the author pushes again. Comments store their line's text to find it again.
- **One review worktree per repository:** reused across reviews, so build caches and language server indexes stay warm. The user's checkout is used directly when it is already at the head commit.
- **git:** reading uses gitoxide. Worktrees and pull-request fetches still call the `git` command; replacing them is issue #1.
- **Review state** (seen hunks, positions, comments, verdict) lives in `.git/trail/<review>.json`, separate from anything the engine can recompute.

## How we work

- **Track gaps as issues:** known gaps and deferred work go into GitHub issues on the repo so they aren't forgotten.
- **Branches and PRs:** one branch and PR per feature or fix, merged when the owner says so. PR text is written to sound human.
- **Tests:** a bug fix starts with a test that fails without it. Engine tests drive the binary over stdio on temporary git repos (`cd engine && cargo test`). The plugin test runs headless (`nvim --headless -u NONE -l test/plugin.lua`).
- **Real sessions:** behavior that headless Neovim can't show, like terminal mode or the tab bar, is checked in a real Neovim session in tmux before calling it done.
