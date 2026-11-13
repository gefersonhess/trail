use std::collections::BTreeMap;
use std::process::Command;
use std::sync::atomic::{AtomicU32, Ordering};

use serde::Deserialize;

use crate::rpc::log;

pub enum Outcome {
    Changed(Structural),
    Unchanged,
}

/// Line numbers are 1-based. Spans are byte ranges within the line.
pub struct Structural {
    pub rows: Vec<(Option<u32>, Option<u32>)>,
    pub old: BTreeMap<u32, Vec<(usize, usize)>>,
    pub new: BTreeMap<u32, Vec<(usize, usize)>>,
}

#[derive(Deserialize)]
struct Output {
    status: String,
    aligned_lines: Option<Vec<(Option<u32>, Option<u32>)>>,
    #[serde(default)]
    chunks: Vec<Vec<Entry>>,
}

#[derive(Deserialize)]
struct Entry {
    lhs: Option<Side>,
    rhs: Option<Side>,
}

#[derive(Deserialize)]
struct Side {
    line_number: u32,
    changes: Vec<Change>,
}

#[derive(Deserialize)]
struct Change {
    start: usize,
    end: usize,
}

/// Runs `difft` on two versions of the file at `path`, whose name picks the language. Returns
/// `None` when difft is missing, fails, or gives no line alignment, so the
/// caller can fall back to a line diff. The JSON format is unstable upstream;
/// this module is the only place that reads it.
pub fn diff(path: &str, old: &str, new: &str) -> Option<Outcome> {
    let name = std::path::Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path);
    let dir = scratch_dir();
    let result = run(&dir, name, old, new);
    let _ = std::fs::remove_dir_all(&dir);
    match result {
        Ok(outcome) => outcome,
        Err(e) => {
            log(&format!("difft failed for {name}, using a line diff: {e}"));
            None
        }
    }
}

fn run(dir: &std::path::Path, name: &str, old: &str, new: &str) -> Result<Option<Outcome>, String> {
    let (old_path, new_path) = (dir.join("old").join(name), dir.join("new").join(name));
    for (path, content) in [(&old_path, old), (&new_path, new)] {
        std::fs::create_dir_all(path.parent().expect("has parent")).map_err(|e| e.to_string())?;
        std::fs::write(path, content).map_err(|e| e.to_string())?;
    }
    let difft = std::env::var("TRAIL_DIFFT").unwrap_or_else(|_| "difft".to_string());
    let out = Command::new(&difft)
        .env("DFT_UNSTABLE", "yes")
        .args(["--display", "json", "--color", "never"])
        .arg(&old_path)
        .arg(&new_path)
        .output()
        .map_err(|e| format!("running {difft}: {e}"))?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    let output: Output = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    Ok(outcome(
        output,
        old.lines().count() as u32,
        new.lines().count() as u32,
    ))
}

fn outcome(output: Output, old_len: u32, new_len: u32) -> Option<Outcome> {
    if output.status == "unchanged" {
        return Some(Outcome::Unchanged);
    }
    let aligned = output.aligned_lines?;
    let in_range = |line: Option<u32>, len: u32| line.filter(|l| *l < len).map(|l| l + 1);
    let rows = aligned
        .into_iter()
        .map(|(o, n)| (in_range(o, old_len), in_range(n, new_len)))
        .filter(|(o, n)| o.is_some() || n.is_some())
        .collect();
    let mut old = BTreeMap::new();
    let mut new = BTreeMap::new();
    for entry in output.chunks.into_iter().flatten() {
        for (side, map) in [(entry.lhs, &mut old), (entry.rhs, &mut new)] {
            if let Some(side) = side {
                let spans: &mut Vec<(usize, usize)> = map.entry(side.line_number + 1).or_default();
                spans.extend(
                    side.changes
                        .iter()
                        .filter(|c| c.start < c.end)
                        .map(|c| (c.start, c.end)),
                );
            }
        }
    }
    Some(Outcome::Changed(Structural { rows, old, new }))
}

fn scratch_dir() -> std::path::PathBuf {
    static COUNTER: AtomicU32 = AtomicU32::new(0);
    std::env::temp_dir().join(format!(
        "trail-difft-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ))
}
