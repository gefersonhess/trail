# trail

Review code changes in Neovim by what they affect, not file by file.

trail groups a change into paths: from the entry points that reach a change, down through the calls it makes. You walk a path as a tree with the diff below and comment as you go. Early work, for Go and Rust.

## Requirements

- Neovim 0.10 or later
- A Rust toolchain, to build the engine
- [difftastic](https://difftastic.wilfred.me.uk/) (`difft`); without it trail falls back to a line diff
- Optional: `gopls` or `rust-analyzer` for exact calls, and `gh` for pull requests

## Install

With lazy.nvim:

```lua
{
  "gefersonhess/trail",
  build = "cd engine && cargo build --release",
  cmd = "Trail",
}
```

## Run

In Neovim:

```
:Trail              " pick an open pull request
:Trail #123         " a pull request, or its URL
:Trail main..feature
```

Or as its own app, without your config, after putting the engine on your `PATH`:

```sh
ln -s ~/.local/share/nvim/lazy/trail/engine/target/release/trail ~/.local/bin/trail
trail '#123'
```

## Review with `]s`

1. The review opens on the overview. Press `<CR>` on the first path.
2. Press `]s` to go to the next change. It lands on the first changed line of the function, and the tree shows where you are: `▶` current, `●` reviewed, `○` not yet.
3. Keep pressing `]s`. It follows the tree: when a branch is done, it goes back to the function it hangs from, on the line calling the next branch, then into it. Hunks count as reviewed once they have been on screen.
4. Comment on a line with `cc` (`cb`, `cq`, `cn` for blocking, question, nit). `K` shows a function's code, `gd` opens its definition.
5. At the end of a path, `-` goes back to the overview for the next one.
6. `S` opens the send screen, where `P` submits the review to the pull request.

`?` lists the keys on any screen.

## More

- [Using trail](docs/usage.md): every screen, key and setting, and the standalone app
- [Design](docs/design.md): how it works
- [Decisions](docs/decisions.md): why it works that way
- [Development](docs/development.md): tests and the engine protocol
