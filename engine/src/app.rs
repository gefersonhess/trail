//! `trail [target]` starts the trail app: Neovim with trail's own config.

use std::path::PathBuf;
use std::process::{Command, ExitCode};

/// Finds `app/init.lua` in the checkout the binary was built in, walking up
/// from `engine/target/<profile>/trail`, through a symlink to it on the PATH.
fn find_init() -> Option<PathBuf> {
    let exe = std::fs::canonicalize(std::env::current_exe().ok()?).ok()?;
    exe.ancestors()
        .map(|dir| dir.join("app").join("init.lua"))
        .find(|init| init.is_file())
}

pub fn launch(args: &[String]) -> ExitCode {
    let own_config = args.iter().any(|a| a == "--my-config");
    let target = args
        .iter()
        .filter(|a| *a != "--my-config")
        .cloned()
        .collect::<Vec<_>>()
        .join(" ");
    let nvim = std::env::var("TRAIL_NVIM").unwrap_or_else(|_| "nvim".to_string());
    let mut cmd = Command::new(&nvim);
    if own_config {
        cmd.arg(format!("+Trail {target}").trim_end());
    } else {
        let Some(init) = std::env::var_os("TRAIL_APP_INIT")
            .map(PathBuf::from)
            .or_else(find_init)
        else {
            eprintln!(
                "trail: app/init.lua not found above {}; set TRAIL_APP_INIT to its path",
                std::env::current_exe().unwrap_or_default().display()
            );
            return ExitCode::FAILURE;
        };
        cmd.arg("-u")
            .arg(init)
            .env("NVIM_APPNAME", "trail")
            .env("TRAIL_ARGS", &target);
        if let Ok(own) = std::env::var("NVIM_APPNAME") {
            cmd.env("TRAIL_USER_APPNAME", own);
        }
    }
    use std::os::unix::process::CommandExt;
    let err = cmd.exec();
    eprintln!("trail: running {nvim}: {err}");
    ExitCode::FAILURE
}
