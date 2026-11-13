# trail

Review code changes inside Neovim as a graph of connected changes instead of a list of files.

trail splits a change into paths: threads of related changes, each starting from an entry point such as a route, a CLI command or a public function. You open a path, see its call graph on top and the diff below, and step through it. Tests get their own section after the code. Comments are collected as you go and copied out at the end.

Status: design. See [docs/design.md](docs/design.md).

Languages: Go and Rust first.
