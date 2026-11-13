use std::path::Path;
use std::process::Command;

pub fn run(repo: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["-c", "core.quotePath=false"])
        .args(args)
        .output()
        .map_err(|e| format!("running git: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

pub fn commit(repo: &Path, rev: &str) -> Result<String, String> {
    if rev.is_empty() || rev.starts_with('-') {
        return Err(format!("invalid revision {rev:?}"));
    }
    let spec = format!("{rev}^{{commit}}");
    Ok(run(
        repo,
        &[
            "rev-parse",
            "--verify",
            "--quiet",
            "--end-of-options",
            &spec,
        ],
    )
    .map_err(|_| format!("unknown revision {rev:?}"))?
    .trim()
    .to_string())
}

pub fn show(repo: &Path, commit: &str, path: &str) -> Result<String, String> {
    run(repo, &["show", &format!("{commit}:{path}")])
}
