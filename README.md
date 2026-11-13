# trail

Review code changes inside Neovim as a graph of connected changes instead of a list of files.

trail splits a change into paths: threads of related changes, each starting from an entry point such as a route, a CLI command or a public function. You open a path, see its call graph on top and the diff below, and step through it. Tests get their own section after the code. Comments are collected as you go and copied out at the end.

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
```

A tab lists the changed functions as a call tree (callers with their callees indented below), then tests, then hunks that are not inside any function. `+`, `~` and `-` mark added, modified and removed functions. `R` reloads, `q` quits.

`<CR>` opens a side-by-side diff at the function or hunk under the cursor. Lines are aligned the way difftastic aligns them, with filler where one side has no matching line. Changed lines get a `-` (base side) or `+` (head side) next to the line number, and only the tokens that actually changed are highlighted, so formatting changes don't show up. Long unchanged stretches are folded, the gutter shows real line numbers, and both sides scroll together. `]h` and `[h` move between changes, `-` goes back to the list. Colors come from highlight groups you can override: `TrailAdd` and `TrailDelete` for the markers, `TrailAddText` and `TrailDeleteText` for changed tokens, `TrailFiller` for filler rows.

This is an early preview to check the engine's output. Paths, the graph view, comments and progress come next. Run its test with `nvim --headless -u NONE -l test/plugin.lua`.

## Engine

```sh
cd engine && cargo build
./target/debug/trail serve
```

`trail serve` reads JSON-RPC 2.0 requests from stdin, one per line, and writes one response per line to stdout. Logs go to stderr. It exits when stdin closes.

```json
{"jsonrpc":"2.0","id":1,"method":"open","params":{"repo":"/path/to/repo","base":"main","head":"feature"}}
```

`open` diffs `head` against its merge base with `base`, ignoring whitespace. For modified Go and Rust files it also asks difftastic, and drops hunks that only reformat code, so a function whose only change is formatting is not listed. Without `difft`, git's whitespace-ignoring diff decides. It returns:

- `base_commit` and `head_commit`: the merge base and head that were compared.
- `files`: path, status, language, whether it is a test.
- `hunks`: id, file, old and new line ranges. Ids hash the file and changed lines, so they stay the same when other hunks shift.
- `nodes`: the Go and Rust functions and methods a hunk touches, found with tree-sitter. Each has an id such as `go:auth.Store.Save` or `rust:auth::hash::verify`, a status (added, modified, removed), old and new ranges, and the ids of its hunks.
- `edges`: calls between changed nodes, as `from`, `to` and a status: `added` (call only in the new code), `removed` (only in the old code) or `unchanged`. They are matched by name with tree-sitter, so their `source` is `name_match` and they should be shown as uncertain. A call matches by how it is written: `a::f()` only a function under `a`, `x.f()` only methods (or, in Go, a function in package `x`), and a bare `f()` only functions, in the same package for Go. Production code never links to test-only functions.

`file_diff` takes `repo`, `base_commit`, `head_commit` and the file's `old_path` and `new_path` (leave one out for an added or deleted file). It returns both versions' lines, `rows` pairing old and new line numbers (`null` for filler), and `old_changes` and `new_changes`: each changed line with the byte ranges of its changed tokens. `engine` says whether difftastic (`difft`, or `TRAIL_DIFFT`) produced it or the plain line diff fallback did.
