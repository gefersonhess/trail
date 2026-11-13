use std::collections::{HashMap, HashSet};

use serde::Serialize;

use crate::diff::{File, Hunk};
use crate::review::{Edge, EdgeStatus, Node, NodeStatus};

/// A thread of related changes to review in order. Each step is a list of
/// node ids shown together.
#[derive(Serialize)]
pub struct Path {
    id: String,
    title: String,
    origin: &'static str,
    entries: Vec<String>,
    steps: Vec<Vec<String>>,
}

#[derive(Serialize)]
pub struct TestFile {
    file: String,
    nodes: Vec<String>,
    hunks: Vec<String>,
    covers: Vec<String>,
}

pub struct Layout {
    pub paths: Vec<Path>,
    pub tests: Vec<TestFile>,
    pub uncovered: Vec<String>,
    pub unassigned: Vec<String>,
}

/// Groups changed code into paths: one per set of non-test functions
/// connected by calls (removed calls included), starting at the functions
/// nothing else in the set calls, with steps in depth-first call order.
/// Larger paths come first.
pub fn layout(files: &[File], hunks: &[Hunk], nodes: &[Node], edges: &[Edge]) -> Layout {
    let code: Vec<&Node> = nodes.iter().filter(|n| !n.is_test).collect();
    let is_code: HashSet<&str> = code.iter().map(|n| n.id.as_str()).collect();
    let mut callees: HashMap<&str, Vec<&str>> = HashMap::new();
    let mut called: HashSet<&str> = HashSet::new();
    let mut neighbours: HashMap<&str, Vec<&str>> = HashMap::new();
    for e in edges {
        let (from, to) = (e.from.as_str(), e.to.as_str());
        if from == to || !is_code.contains(from) || !is_code.contains(to) {
            continue;
        }
        callees.entry(from).or_default().push(to);
        called.insert(to);
        neighbours.entry(from).or_default().push(to);
        neighbours.entry(to).or_default().push(from);
    }

    let order: HashMap<&str, usize> = code
        .iter()
        .enumerate()
        .map(|(i, n)| (n.id.as_str(), i))
        .collect();
    let mut component_of: HashMap<&str, usize> = HashMap::new();
    let mut components: Vec<Vec<&str>> = Vec::new();
    for node in &code {
        if component_of.contains_key(node.id.as_str()) {
            continue;
        }
        let index = components.len();
        let mut members = Vec::new();
        let mut stack = vec![node.id.as_str()];
        while let Some(id) = stack.pop() {
            if component_of.contains_key(id) {
                continue;
            }
            component_of.insert(id, index);
            members.push(id);
            stack.extend(neighbours.get(id).into_iter().flatten().copied());
        }
        members.sort_by_key(|id| order[id]);
        components.push(members);
    }

    let mut paths: Vec<Path> = components
        .iter()
        .map(|members| {
            let mut entries: Vec<&str> = members
                .iter()
                .copied()
                .filter(|id| !called.contains(id))
                .collect();
            if entries.is_empty() {
                entries.push(members[0]);
            }
            let mut visited = HashSet::new();
            let mut steps = Vec::new();
            for start in entries.iter().chain(members.iter()) {
                visit(start, &callees, &mut visited, &mut steps);
            }
            Path {
                id: format!("path:{}", entries[0]),
                title: entries
                    .iter()
                    .map(|e| short(e))
                    .collect::<Vec<_>>()
                    .join(", "),
                origin: "graph",
                entries: entries.iter().map(|e| e.to_string()).collect(),
                steps,
            }
        })
        .collect();
    paths.sort_by_key(|p| std::cmp::Reverse(p.steps.len()));

    let live_callees: HashMap<&str, Vec<&str>> = {
        let mut map: HashMap<&str, Vec<&str>> = HashMap::new();
        for e in edges.iter().filter(|e| e.status != EdgeStatus::Removed) {
            map.entry(e.from.as_str()).or_default().push(e.to.as_str());
        }
        map
    };
    let mut covered: HashSet<&str> = HashSet::new();
    let mut tests: Vec<TestFile> = Vec::new();
    for file in files.iter().filter(|f| f.is_test) {
        let test_nodes: Vec<&Node> = nodes
            .iter()
            .filter(|n| n.is_test && n.file == file.path)
            .collect();
        let mut reached = Vec::new();
        let mut stack: Vec<&str> = test_nodes.iter().map(|n| n.id.as_str()).collect();
        let mut seen: HashSet<&str> = HashSet::new();
        while let Some(id) = stack.pop() {
            for to in live_callees.get(id).into_iter().flatten() {
                if seen.insert(to) {
                    stack.push(to);
                    if is_code.contains(to) {
                        reached.push(*to);
                    }
                }
            }
        }
        covered.extend(reached.iter().copied());
        reached.sort_by_key(|id| order[id]);
        tests.push(TestFile {
            file: file.path.clone(),
            nodes: test_nodes.iter().map(|n| n.id.clone()).collect(),
            hunks: hunks
                .iter()
                .filter(|h| h.file == file.path)
                .map(|h| h.id.clone())
                .collect(),
            covers: reached.iter().map(|id| id.to_string()).collect(),
        });
    }
    // Test functions in non-test files (Rust `mod tests`) join their file's entry.
    for node in nodes.iter().filter(|n| n.is_test) {
        if !tests.iter().any(|t| t.nodes.contains(&node.id)) {
            match tests.iter_mut().find(|t| t.file == node.file) {
                Some(t) => t.nodes.push(node.id.clone()),
                None => tests.push(TestFile {
                    file: node.file.clone(),
                    nodes: vec![node.id.clone()],
                    hunks: node.hunks.clone(),
                    covers: Vec::new(),
                }),
            }
        }
    }

    let uncovered = code
        .iter()
        .filter(|n| n.status != NodeStatus::Removed && !covered.contains(n.id.as_str()))
        .map(|n| n.id.clone())
        .collect();
    let placed: HashSet<&str> = nodes
        .iter()
        .flat_map(|n| n.hunks.iter().map(String::as_str))
        .chain(
            tests
                .iter()
                .flat_map(|t| t.hunks.iter().map(String::as_str)),
        )
        .collect();
    let unassigned = hunks
        .iter()
        .filter(|h| !placed.contains(h.id.as_str()))
        .map(|h| h.id.clone())
        .collect();
    Layout {
        paths,
        tests,
        uncovered,
        unassigned,
    }
}

fn visit<'a>(
    id: &'a str,
    callees: &HashMap<&'a str, Vec<&'a str>>,
    visited: &mut HashSet<&'a str>,
    steps: &mut Vec<Vec<String>>,
) {
    if !visited.insert(id) {
        return;
    }
    steps.push(vec![id.to_string()]);
    for to in callees.get(id).into_iter().flatten() {
        visit(to, callees, visited, steps);
    }
}

/// `go:auth.Store.Save` → `auth.Store.Save`.
fn short(id: &str) -> &str {
    id.split_once(':').map_or(id, |(_, rest)| rest)
}
