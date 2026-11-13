# trail

Review code changes inside Neovim as a graph of connected changes instead of a list of files.

trail splits a change into paths: threads of related changes, each starting from an entry point such as a route, a CLI command or a public function. You open a path, see its call graph on top and the diff below, and step through it. Tests get their own section after the code. Comments are collected as you go and copied out at the end.

Status: design. See [docs/design.md](docs/design.md).

Languages: Go and Rust first.

## Engine

```sh
cd engine && cargo build
./target/debug/trail serve
```

`trail serve` reads JSON-RPC 2.0 requests from stdin, one per line, and writes one response per line to stdout. Logs go to stderr. It exits when stdin closes.

```json
{"jsonrpc":"2.0","id":1,"method":"open","params":{"repo":"/path/to/repo","base":"main","head":"feature"}}
```

`open` diffs `head` against its merge base with `base`, ignoring whitespace, and returns:

- `base_commit` and `head_commit`: the merge base and head that were compared.
- `files`: path, status, language, whether it is a test.
- `hunks`: id, file, old and new line ranges. Ids hash the file and changed lines, so they stay the same when other hunks shift.
- `nodes`: the Go and Rust functions and methods a hunk touches, found with tree-sitter. Each has an id such as `go:auth.Store.Save` or `rust:auth::hash::verify`, a status (added, modified, removed), old and new ranges, and the ids of its hunks.
