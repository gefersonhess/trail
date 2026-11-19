mod app;
mod diff;
mod difftastic;
mod git;
mod impact;
mod lsp;
mod paths;
mod peek;
mod pull_request;
mod review;
mod rpc;
mod sidebyside;
mod symbols;
mod worktree;

use std::process::ExitCode;

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("serve") => match rpc::serve(std::io::stdin().lock(), std::io::stdout()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("trail: {e}");
                ExitCode::FAILURE
            }
        },
        Some("-h" | "--help") => {
            println!(
                "usage:\n  trail [--my-config] [#123 | <pull request url> | base..head]   open the trail app\n  trail serve   run the engine over JSON-RPC on stdio"
            );
            ExitCode::SUCCESS
        }
        _ => app::launch(&std::env::args().skip(1).collect::<Vec<_>>()),
    }
}
