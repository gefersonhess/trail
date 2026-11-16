//! Impact paths: from each changed function, everything that can reach it up to
//! the entry points, and everything it calls, through unchanged code. Changed
//! functions whose impact reaches each other share a path.

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{Value, json};

use crate::diff;
use crate::git;
use crate::lsp;
use crate::review::{self, NodeStatus};
use crate::rpc::log;
use crate::symbols::{self, Kind, Symbol};
use crate::worktree;

#[derive(Serialize)]
pub struct Impact {
    pub paths: Vec<ImpactPath>,
}

#[derive(Serialize)]
pub struct ImpactPath {
    pub id: String,
    /// The changed functions in the order the trees show them.
    pub steps: Vec<String>,
    pub nodes: Vec<ImpactNode>,
    pub edges: Vec<ImpactEdge>,
    /// The path read from beginning to end: one tree per entry point, the one
    /// through most changes first, each later tree stopping where it joins
    /// one shown before.
    pub trees: Vec<Tree>,
    /// The walk hit the node or time limit, so some callers or callees are missing.
    pub truncated: bool,
}

#[derive(Serialize)]
pub struct Tree {
    pub rows: Vec<Row>,
    /// A changed function appears in it before it joins an earlier tree.
    pub changes: bool,
}

#[derive(Serialize)]
pub struct Row {
    pub id: String,
    pub depth: usize,
    /// The interface or trait method the call from the row above goes through.
    pub via: Option<String>,
    /// Already shown earlier, so its callees are not repeated here.
    pub join: bool,
}

#[derive(Serialize)]
pub struct ImpactNode {
    pub id: String,
    pub name: String,
    pub file: String,
    /// 1-based line of the function's name at head.
    pub line: u32,
    pub status: &'static str,
    pub is_test: bool,
    /// Nothing outside test files calls it.
    pub entry: bool,
}

#[derive(Serialize, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct ImpactEdge {
    pub from: String,
    pub to: String,
    /// The interface or trait method the call goes through, when it is not direct.
    pub via: Option<String>,
    pub source: &'static str,
}

/// A function by file and the 1-based line of its name at head.
type Key = (String, u32);

#[derive(Clone, PartialEq, Eq, PartialOrd, Ord)]
struct Link {
    key: Key,
    via: Option<String>,
    /// Through an interface declared outside the repository, like `io.Writer`,
    /// which connects too much to join paths.
    outside: bool,
}

/// Functions at head, parsed on demand.
struct Sources {
    repo: PathBuf,
    commit: String,
    language: &'static str,
    symbols: HashMap<String, Vec<Symbol>>,
}

impl Sources {
    fn symbols(&mut self, file: &str) -> &[Symbol] {
        if !self.symbols.contains_key(file) {
            let parsed = git::show(&self.repo, &self.commit, file)
                .map(|src| symbols::extract(self.language, file, &src))
                .unwrap_or_default();
            self.symbols.insert(file.to_string(), parsed);
        }
        &self.symbols[file]
    }

    /// The function or method declared with its name on `key`'s line.
    fn function(&mut self, key: &Key) -> Option<&Symbol> {
        self.symbols(&key.0)
            .iter()
            .find(|s| is_function(s) && s.name_at.0 + 1 == key.1)
    }

    /// The named function around a function literal on `key`'s line.
    fn enclosing(&mut self, key: &Key) -> Option<Key> {
        if self.function(key).is_some() {
            return None;
        }
        let line = key.1;
        self.symbols(&key.0)
            .iter()
            .filter(|s| is_function(s) && s.start <= line && line <= s.end)
            .min_by_key(|s| s.end - s.start)
            .map(|s| (key.0.clone(), s.name_at.0 + 1))
    }

    fn name(&mut self, key: &Key) -> String {
        if let Some(function) = self.function(key) {
            return function.name.clone();
        }
        match self.enclosing(key) {
            Some(outer) => format!("{} (func literal)", self.name(&outer)),
            None => format!("{}:{}", key.0, key.1),
        }
    }

    fn is_type(&mut self, key: &Key) -> bool {
        self.symbols(&key.0)
            .iter()
            .any(|s| s.kind == Kind::Type && s.name_at.0 + 1 == key.1)
    }

    /// A method declared inside an interface or trait, which calls dispatch through.
    fn is_abstract(&mut self, key: &Key) -> bool {
        let line = key.1;
        self.symbols(&key.0)
            .iter()
            .filter(|s| s.start <= line && line <= s.end)
            .min_by_key(|s| s.end - s.start)
            .is_some_and(|s| s.kind == Kind::Type)
    }

    /// `Saver.Save` for a method declared in `Saver` on `key`'s line.
    fn abstract_name(&mut self, key: &Key, method: &str) -> String {
        let line = key.1;
        self.symbols(&key.0)
            .iter()
            .filter(|s| s.kind == Kind::Type && s.start <= line && line <= s.end)
            .min_by_key(|s| s.end - s.start)
            .map_or_else(
                || format!("{}:{}", key.0, key.1),
                |t| format!("{}.{method}", t.name),
            )
    }
}

fn is_function(symbol: &Symbol) -> bool {
    matches!(symbol.kind, Kind::Function | Kind::Method)
}

fn short_name(name: &str) -> &str {
    name.rsplit(['.', ':']).next().unwrap_or(name)
}

trait Calls {
    fn callers(&mut self, key: &Key, sources: &mut Sources) -> Result<Vec<Link>, String>;
    fn callees(&mut self, key: &Key, sources: &mut Sources) -> Result<Vec<Link>, String>;
}

/// Calls from the language server's call hierarchy.
struct Server<'a> {
    client: &'a mut lsp::Client,
    root: PathBuf,
    items: HashMap<Key, Value>,
    deadline: Instant,
}

impl Server<'_> {
    fn left(&self) -> Duration {
        self.deadline.saturating_duration_since(Instant::now())
    }

    fn key(&self, uri: &Value, line: &Value) -> Option<Key> {
        let path = lsp::path_of(uri.as_str()?)?;
        let rel = path.strip_prefix(&self.root).ok()?;
        Some((
            rel.to_string_lossy().into_owned(),
            line.as_u64()? as u32 + 1,
        ))
    }

    fn position(&self, key: &Key, character: u64) -> Value {
        json!({
            "textDocument": { "uri": lsp::uri(&self.root.join(&key.0)) },
            "position": { "line": key.1 - 1, "character": character },
        })
    }

    /// Prepares the call hierarchy item at `key`, asking again until `until`
    /// while the server is still loading the workspace and answers with nothing.
    fn prepare(&mut self, key: &Key, character: usize, until: Instant) -> Result<bool, String> {
        let params = self.position(key, character as u64);
        loop {
            let items = self.client.request(
                "textDocument/prepareCallHierarchy",
                params.clone(),
                self.left(),
            )?;
            if let Some(item) = items.as_array().and_then(|a| a.first()) {
                self.items.insert(key.clone(), item.clone());
                return Ok(true);
            }
            if Instant::now() >= until {
                return Ok(false);
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    }

    fn locations(result: &Value) -> Vec<(Value, Value)> {
        let list = match result {
            Value::Array(a) => a.clone(),
            Value::Null => Vec::new(),
            other => vec![other.clone()],
        };
        list.into_iter()
            .map(|l| {
                let uri = l
                    .get("targetUri")
                    .or(l.get("uri"))
                    .cloned()
                    .unwrap_or_default();
                let range = l
                    .get("targetSelectionRange")
                    .or(l.get("range"))
                    .cloned()
                    .unwrap_or_default();
                (uri, range)
            })
            .collect()
    }
}

impl Calls for Server<'_> {
    fn callers(&mut self, key: &Key, sources: &mut Sources) -> Result<Vec<Link>, String> {
        let Some(item) = self.items.get(key).cloned() else {
            return Ok(Vec::new());
        };
        let method = item["name"].as_str().unwrap_or_default().to_string();
        let calls = self.client.request(
            "callHierarchy/incomingCalls",
            json!({ "item": item }),
            self.left(),
        )?;
        let mut out = Vec::new();
        for call in calls.as_array().into_iter().flatten() {
            let mut outside = false;
            let from = &call["from"];
            let Some(caller) = self.key(&from["uri"], &from["selectionRange"]["start"]["line"])
            else {
                continue;
            };
            self.items.insert(caller.clone(), from.clone());
            // The call site's definition is the interface method when the call dispatches through one.
            let mut via = None;
            if let Some(site) = call["fromRanges"].as_array().and_then(|r| r.first()) {
                let params = json!({
                    "textDocument": { "uri": from["uri"] },
                    "position": site["start"],
                });
                let target = self
                    .client
                    .request("textDocument/definition", params, self.left())?;
                if let Some((uri, range)) = Self::locations(&target).first() {
                    let line = range["start"]["line"].as_u64().unwrap_or(0) as u32 + 1;
                    match self.key(uri, &range["start"]["line"]) {
                        Some(defined) if &defined != key && sources.is_abstract(&defined) => {
                            via = Some(sources.abstract_name(&defined, &method));
                        }
                        Some(_) => {}
                        None => {
                            via = outside_interface(uri, line, &method, sources.language);
                            outside = via.is_some();
                        }
                    }
                }
            }
            out.push(Link {
                key: caller,
                via,
                outside,
            });
        }
        Ok(out)
    }

    fn callees(&mut self, key: &Key, sources: &mut Sources) -> Result<Vec<Link>, String> {
        let Some(item) = self.items.get(key).cloned() else {
            return Ok(Vec::new());
        };
        let calls = self.client.request(
            "callHierarchy/outgoingCalls",
            json!({ "item": item }),
            self.left(),
        )?;
        let mut out = Vec::new();
        for call in calls.as_array().into_iter().flatten() {
            let to = &call["to"];
            let Some(callee) = self.key(&to["uri"], &to["selectionRange"]["start"]["line"]) else {
                continue;
            };
            // A conversion like `T(x)` comes back as a call to the type.
            if sources.is_type(&callee) {
                continue;
            }
            if !sources.is_abstract(&callee) {
                self.items.insert(callee.clone(), to.clone());
                out.push(Link {
                    key: callee,
                    via: None,
                    outside: false,
                });
                continue;
            }
            // Outgoing calls stop at the interface method: continue through its implementations.
            let method = to["name"].as_str().unwrap_or_default();
            let via = sources.abstract_name(&callee, method);
            let character = to["selectionRange"]["start"]["character"]
                .as_u64()
                .unwrap_or(0);
            let found = self.client.request(
                "textDocument/implementation",
                self.position(&callee, character),
                self.left(),
            )?;
            let mut implemented = false;
            for (uri, range) in Self::locations(&found) {
                let Some(implementation) = self.key(&uri, &range["start"]["line"]) else {
                    continue;
                };
                if implementation == callee {
                    continue;
                }
                let at = range["start"]["character"].as_u64().unwrap_or(0) as usize;
                if !self.items.contains_key(&implementation) {
                    self.prepare(&implementation, at, Instant::now())?;
                }
                implemented = true;
                out.push(Link {
                    key: implementation,
                    via: Some(via.clone()),
                    outside: false,
                });
            }
            if !implemented {
                self.items.insert(callee.clone(), to.clone());
                out.push(Link {
                    key: callee,
                    via: None,
                    outside: false,
                });
            }
        }
        Ok(out)
    }
}

/// `http.ResponseWriter.WriteHeader` for a method of an interface declared
/// outside the repository, such as in the standard library.
fn outside_interface(uri: &Value, line: u32, method: &str, language: &str) -> Option<String> {
    let path = lsp::path_of(uri.as_str()?)?;
    let source = std::fs::read_to_string(&path).ok()?;
    let package = path.parent()?.file_name()?.to_string_lossy().into_owned();
    let symbols = symbols::extract(language, &path.to_string_lossy(), &source);
    let around = symbols
        .iter()
        .filter(|s| s.start <= line && line <= s.end)
        .min_by_key(|s| s.end - s.start)?;
    (around.kind == Kind::Type).then(|| format!("{package}.{}.{method}", short_name(&around.name)))
}

/// Calls matched by name with tree-sitter, when no language server answers.
struct Names {
    pattern: &'static str,
    containing: HashMap<String, Vec<String>>,
}

impl Names {
    fn files(&mut self, word: &str, sources: &Sources) -> Result<Vec<String>, String> {
        if !self.containing.contains_key(word) {
            let files = git::files_containing(&sources.repo, &sources.commit, word, self.pattern)?;
            self.containing.insert(word.to_string(), files);
        }
        Ok(self.containing[word].clone())
    }
}

impl Calls for Names {
    fn callers(&mut self, key: &Key, sources: &mut Sources) -> Result<Vec<Link>, String> {
        let Some(name) = sources
            .function(key)
            .map(|s| short_name(&s.name).to_string())
        else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        for file in self.files(&name, sources)? {
            for symbol in sources.symbols(&file) {
                if is_function(symbol) && symbol.calls.iter().any(|c| c.name == name) {
                    out.push(Link {
                        key: (file.clone(), symbol.name_at.0 + 1),
                        via: None,
                        outside: false,
                    });
                }
            }
        }
        Ok(out)
    }

    fn callees(&mut self, key: &Key, sources: &mut Sources) -> Result<Vec<Link>, String> {
        let Some(mut names) = sources
            .function(key)
            .map(|s| s.calls.iter().map(|c| c.name.clone()).collect::<Vec<_>>())
        else {
            return Ok(Vec::new());
        };
        names.sort();
        names.dedup();
        let mut out = Vec::new();
        for name in names {
            for file in self.files(&name, sources)? {
                for symbol in sources.symbols(&file) {
                    if is_function(symbol) && short_name(&symbol.name) == name {
                        out.push(Link {
                            key: (file.clone(), symbol.name_at.0 + 1),
                            via: None,
                            outside: false,
                        });
                    }
                }
            }
        }
        Ok(out)
    }
}

/// What one changed function reaches.
struct Reach {
    up: Vec<Key>,
    down: Vec<Key>,
    /// Reached without an interface from outside the repository on the way,
    /// so a changed function among them shares the path.
    joins: HashSet<Key>,
    edges: Vec<(Key, Key, Option<String>)>,
    truncated: bool,
}

struct Walker<'a> {
    calls: &'a mut dyn Calls,
    sources: &'a mut Sources,
    callers: HashMap<Key, Vec<Link>>,
    callees: HashMap<Key, Vec<Link>>,
    entries: HashSet<Key>,
    limit: usize,
    deadline: Instant,
}

impl Walker<'_> {
    fn links(&mut self, key: &Key, up: bool) -> Result<Vec<Link>, String> {
        let cache = if up { &self.callers } else { &self.callees };
        if let Some(links) = cache.get(key) {
            return Ok(links.clone());
        }
        let mut found = if up {
            self.calls.callers(key, self.sources)?
        } else {
            self.calls.callees(key, self.sources)?
        };
        // Nothing calls a function literal by name; the walk goes on through the function that holds it.
        if up
            && found.is_empty()
            && let Some(outer) = self.sources.enclosing(key)
        {
            found.push(Link {
                key: outer,
                via: None,
                outside: false,
            });
        }
        let mut links: Vec<Link> = found.into_iter().filter(|l| &l.key != key).collect();
        links.sort();
        links.dedup();
        let cache = if up {
            &mut self.callers
        } else {
            &mut self.callees
        };
        cache.insert(key.clone(), links.clone());
        Ok(links)
    }

    /// Breadth first from `root`, callers when `up`, else callees.
    fn walk(&mut self, root: &Key, up: bool, reach: &mut Reach) -> Result<(), String> {
        let mut seen: HashSet<Key> = HashSet::from([root.clone()]);
        reach.joins.insert(root.clone());
        let mut queue = VecDeque::from([root.clone()]);
        while let Some(key) = queue.pop_front() {
            if Instant::now() >= self.deadline {
                reach.truncated = true;
                break;
            }
            let links = match self.links(&key, up) {
                Ok(links) => links,
                Err(_) if Instant::now() >= self.deadline => {
                    reach.truncated = true;
                    break;
                }
                Err(e) => return Err(e),
            };
            if up && !diff::is_test(&key.0) && links.iter().all(|l| diff::is_test(&l.key.0)) {
                self.entries.insert(key.clone());
            }
            for Link {
                key: next,
                via,
                outside,
            } in links
            {
                if !outside && reach.joins.contains(&key) {
                    reach.joins.insert(next.clone());
                }
                if !seen.contains(&next) {
                    if seen.len() >= self.limit {
                        reach.truncated = true;
                        continue;
                    }
                    seen.insert(next.clone());
                    queue.push_back(next.clone());
                    if up {
                        reach.up.push(next.clone());
                    } else {
                        reach.down.push(next.clone());
                    }
                }
                let edge = if up {
                    (next, key.clone(), via)
                } else {
                    (key.clone(), next, via)
                };
                reach.edges.push(edge);
            }
        }
        Ok(())
    }
}

struct Changed {
    id: String,
    status: &'static str,
    is_test: bool,
    name_at: (u32, usize),
}

/// The walk of one language's changed functions.
struct Walked {
    reaches: Vec<(Key, Reach)>,
    entries: HashSet<Key>,
    /// `lsp`, or `name_match` when no language server answered.
    source: &'static str,
    sources: Sources,
}

/// Walks every changed function of one language, with its language server
/// when one answers, else by name.
fn walk_language(
    repo: &Path,
    head_commit: &str,
    language: &'static str,
    changed: &HashMap<Key, Changed>,
    limit: usize,
    deadline: Instant,
) -> Result<Walked, String> {
    let mut roots: Vec<Key> = changed
        .iter()
        .filter(|(k, c)| !c.is_test && language_of(&k.0) == Some(language))
        .map(|(k, _)| k.clone())
        .collect();
    roots.sort();
    let run = |calls: &mut dyn Calls, source: &'static str| -> Result<Walked, String> {
        let mut sources = Sources {
            repo: repo.to_path_buf(),
            commit: head_commit.to_string(),
            language,
            symbols: HashMap::new(),
        };
        let mut walker = Walker {
            calls,
            sources: &mut sources,
            callers: HashMap::new(),
            callees: HashMap::new(),
            entries: HashSet::new(),
            limit,
            deadline,
        };
        let mut reaches = Vec::new();
        for root in &roots {
            let mut reach = Reach {
                up: vec![root.clone()],
                down: Vec::new(),
                joins: HashSet::new(),
                edges: Vec::new(),
                truncated: false,
            };
            walker.walk(root, true, &mut reach)?;
            walker.walk(root, false, &mut reach)?;
            reaches.push((root.clone(), reach));
        }
        let entries = walker.entries;
        Ok(Walked {
            reaches,
            entries,
            source,
            sources,
        })
    };

    let served = worktree::checkout(repo, head_commit).and_then(|checkout| {
        lsp::with_client(language, &checkout.path, head_commit, |client| {
            let mut server = Server {
                client,
                root: checkout.path.clone(),
                items: HashMap::new(),
                deadline,
            };
            // Wait for the workspace to load only until the first function is found.
            let loading = Instant::now() + Duration::from_secs(setting("TRAIL_LSP_TIMEOUT", 60));
            let mut loaded = false;
            for root in &roots {
                let until = if loaded {
                    Instant::now()
                } else {
                    loading.min(deadline)
                };
                match server.prepare(root, changed[root].name_at.1, until) {
                    Ok(found) => loaded |= found,
                    // A file the build leaves out has no package for the server to place it in.
                    Err(e) => log(&format!("impact: skipping {}:{}: {e}", root.0, root.1)),
                }
            }
            if !loaded {
                return Err(format!(
                    "{language} language server found none of the changed functions"
                ));
            }
            run(&mut server, "lsp")
        })
    });
    served.or_else(|e| {
        log(&format!(
            "impact: {language} language server unavailable, matching by name: {e}"
        ));
        let mut names = Names {
            pattern: if language == "rust" { "*.rs" } else { "*.go" },
            containing: HashMap::new(),
        };
        run(&mut names, "name_match")
    })
}

fn language_of(file: &str) -> Option<&'static str> {
    match Path::new(file).extension()?.to_str()? {
        "go" => Some("go"),
        "rs" => Some("rust"),
        _ => None,
    }
}

fn setting(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

pub fn compute(repo: &Path, base: &str, head: &str) -> Result<Impact, String> {
    let review = review::open(repo, base, head, false)?;
    let mut changed: HashMap<Key, Changed> = HashMap::new();
    for node in &review.nodes {
        let Some(name_at) = node.head_function_at() else {
            continue;
        };
        let status = match node.status {
            NodeStatus::Added => "added",
            NodeStatus::Modified => "modified",
            _ => continue,
        };
        changed.insert(
            (node.file.clone(), name_at.0 + 1),
            Changed {
                id: node.id.clone(),
                status,
                is_test: node.is_test,
                name_at,
            },
        );
    }
    let limit = setting("TRAIL_IMPACT_LIMIT", 2000) as usize;
    let deadline = Instant::now() + Duration::from_secs(setting("TRAIL_IMPACT_TIMEOUT", 120));
    let mut languages: Vec<&'static str> =
        changed.keys().filter_map(|k| language_of(&k.0)).collect();
    languages.sort_unstable();
    languages.dedup();

    let mut paths = Vec::new();
    for language in languages {
        let mut walked = walk_language(
            repo,
            &review.head_commit,
            language,
            &changed,
            limit,
            deadline,
        )?;
        paths.extend(group(&mut walked, &changed));
    }
    paths.sort_by(|a, b| b.nodes.len().cmp(&a.nodes.len()).then(a.id.cmp(&b.id)));
    Ok(Impact { paths })
}

/// Joins changed functions whose impact reaches each other into paths.
fn group(walked: &mut Walked, changed: &HashMap<Key, Changed>) -> Vec<ImpactPath> {
    let Walked {
        reaches,
        entries,
        source,
        sources,
    } = walked;
    let source = *source;
    let index: HashMap<&Key, usize> = reaches
        .iter()
        .enumerate()
        .map(|(i, (k, _))| (k, i))
        .collect();
    let mut parent: Vec<usize> = (0..reaches.len()).collect();
    fn find(parent: &mut [usize], i: usize) -> usize {
        let mut i = i;
        while parent[i] != i {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        i
    }
    for (i, (_, reach)) in reaches.iter().enumerate() {
        for key in &reach.joins {
            if let Some(&j) = index.get(key) {
                let (a, b) = (find(&mut parent, i), find(&mut parent, j));
                parent[a] = b;
            }
        }
    }
    let mut groups: HashMap<usize, Vec<usize>> = HashMap::new();
    for i in 0..reaches.len() {
        let g = find(&mut parent, i);
        groups.entry(g).or_default().push(i);
    }

    let id_of = |key: &Key| {
        changed
            .get(key)
            .map_or_else(|| format!("{}:{}", key.0, key.1), |c| c.id.clone())
    };
    let mut out = Vec::new();
    for members in groups.into_values() {
        let mut keys: Vec<Key> = Vec::new();
        let mut edges: Vec<ImpactEdge> = Vec::new();
        let mut truncated = false;
        for &i in &members {
            let reach = &reaches[i].1;
            truncated |= reach.truncated;
            keys.extend(reach.up.iter().chain(&reach.down).cloned());
            edges.extend(reach.edges.iter().map(|(from, to, via)| ImpactEdge {
                from: id_of(from),
                to: id_of(to),
                via: via.clone(),
                source,
            }));
        }
        keys.sort();
        keys.dedup();
        edges.sort();
        edges.dedup();
        let nodes = keys
            .iter()
            .map(|key| {
                let name = sources.name(key);
                let is_test = diff::is_test(&key.0);
                ImpactNode {
                    id: id_of(key),
                    name,
                    file: key.0.clone(),
                    line: key.1,
                    status: changed.get(key).map_or("unchanged", |c| c.status),
                    is_test,
                    entry: !is_test && entries.contains(key),
                }
            })
            .collect::<Vec<_>>();
        let own: HashSet<String> = members.iter().map(|&i| id_of(&reaches[i].0)).collect();
        let (trees, steps) = layout(&nodes, &edges, &own);
        out.push(ImpactPath {
            id: steps[0].clone(),
            steps,
            nodes,
            edges,
            trees,
            truncated,
        });
    }
    out
}

/// Lays a path out as trees from its entry points down, and lists its own
/// changed functions in the order the trees show them. A change that belongs
/// to another path still shows in the trees, without being a step.
fn layout(
    nodes: &[ImpactNode],
    edges: &[ImpactEdge],
    own: &HashSet<String>,
) -> (Vec<Tree>, Vec<String>) {
    let node: HashMap<&str, &ImpactNode> = nodes.iter().map(|n| (n.id.as_str(), n)).collect();
    let is_test = |id: &str| node[id].is_test;
    let is_changed = |id: &str| own.contains(id);
    let mut callees: HashMap<&str, Vec<(&str, Option<&str>)>> = HashMap::new();
    let mut called: HashSet<&str> = HashSet::new();
    for e in edges.iter().filter(|e| !is_test(&e.from)) {
        callees
            .entry(&e.from)
            .or_default()
            .push((&e.to, e.via.as_deref()));
        called.insert(&e.to);
    }
    let changes_below = |start: &str| {
        let mut seen = HashSet::from([start]);
        let mut queue = vec![start];
        while let Some(id) = queue.pop() {
            for &(next, _) in callees.get(id).into_iter().flatten() {
                if seen.insert(next) {
                    queue.push(next);
                }
            }
        }
        seen.into_iter().filter(|&id| is_changed(id)).count()
    };
    let mut weight: HashMap<&str, usize> = HashMap::new();
    for n in nodes {
        weight.insert(&n.id, changes_below(&n.id));
    }
    let order = |a: &&str, b: &&str| {
        weight[b]
            .cmp(&weight[a])
            .then(node[a].name.cmp(&node[b].name))
    };
    for list in callees.values_mut() {
        list.sort_by(|a, b| order(&a.0, &b.0));
        list.dedup_by(|a, b| a.0 == b.0);
    }

    let mut starts: Vec<&str> = nodes
        .iter()
        .map(|n| n.id.as_str())
        .filter(|id| !is_test(id) && !called.contains(id))
        .collect();
    starts.sort_by(order);
    // Changed functions only reachable through a cycle get a tree of their own.
    let mut rest: Vec<&str> = nodes
        .iter()
        .map(|n| n.id.as_str())
        .filter(|&id| is_changed(id))
        .collect();
    rest.sort_by(order);

    let mut shown: HashSet<&str> = HashSet::new();
    let mut trees = Vec::new();
    let mut steps = Vec::new();
    for start in starts.into_iter().chain(rest) {
        if shown.contains(start) {
            continue;
        }
        let mut rows = Vec::new();
        let mut changes = false;
        let mut stack: Vec<(&str, usize, Option<&str>)> = vec![(start, 0, None)];
        while let Some((id, depth, via)) = stack.pop() {
            let join = !shown.insert(id);
            if !join {
                if is_changed(id) {
                    changes = true;
                    steps.push(id.to_string());
                }
                for &(next, next_via) in callees.get(id).into_iter().flatten().rev() {
                    stack.push((next, depth + 1, next_via));
                }
            }
            rows.push(Row {
                id: id.to_string(),
                depth,
                via: via.map(str::to_string),
                join,
            });
        }
        trees.push(Tree { rows, changes });
    }
    (trees, steps)
}
