# Development

```sh
cd engine && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test
nvim --headless -u NONE -l test/plugin.lua   # needs a built engine and difft
```

The engine, `trail serve`, speaks JSON-RPC 2.0 over stdio, one message per line, logging to stderr. Methods: `open` (files, hunks, nodes, call edges), `impact` (paths), `file_diff` (aligned rows and changed tokens for one file), `peek` (find a function by name), `checkout` (a worktree at a commit) and `pull_request`. What `open` and `impact` return is described in [design.md](design.md).
