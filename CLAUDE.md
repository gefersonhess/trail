# trail

A git code review tool: a Rust engine (`engine/`, `trail serve`, JSON-RPC over stdio) and a Neovim plugin (`lua/trail/`, `:Trail`).

Read before changing behavior:
- `docs/decisions.md`: what was decided and why, including approaches that were tried and dropped.
- `docs/design.md`: how trail works.
- `README.md`: install and keys.

Before calling work done, all of these must pass:
- `cd engine && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test`
- `nvim --headless -u NONE -l test/plugin.lua` (needs a built engine and `difft`)

Known gaps are GitHub issues on gefersonhess/trail.
