mod diff;
mod git;
mod review;
mod rpc;
mod symbols;

use std::process::ExitCode;

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref() {
        Some("serve") => match rpc::serve(std::io::stdin().lock(), std::io::stdout().lock()) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("trail: {e}");
                ExitCode::FAILURE
            }
        },
        _ => {
            eprintln!("usage: trail serve");
            ExitCode::from(2)
        }
    }
}
