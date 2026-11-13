use tree_sitter::{Node, Parser};

pub struct Symbol {
    pub name: String,
    pub kind: Kind,
    pub start: u32,
    pub end: u32,
    /// Where the name itself starts: 0-based row and UTF-16 column, as LSP counts.
    pub name_at: (u32, usize),
    pub calls: Vec<Call>,
}

#[derive(Clone)]
pub struct Call {
    pub name: String,
    pub via: Via,
}

/// How the callee was written, which decides what it can match.
#[derive(Clone)]
pub enum Via {
    /// `f()`
    Plain,
    /// `a::f()`, with the last path segment.
    Path(String),
    /// `x.f()`, with `x` when it is a plain name. In Go `x` may also be a package.
    Receiver(Option<String>),
}

#[derive(Clone, Copy, PartialEq, serde::Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    Function,
    Method,
}

/// Lines are 1-based and inclusive, matching git's hunk ranges.
pub fn extract(language: &str, path: &str, source: &str) -> Vec<Symbol> {
    let grammar = match language {
        "go" => tree_sitter_go::LANGUAGE,
        "rust" => tree_sitter_rust::LANGUAGE,
        _ => return Vec::new(),
    };
    let mut parser = Parser::new();
    parser
        .set_language(&grammar.into())
        .expect("grammar matches tree-sitter version");
    let Some(tree) = parser.parse(source, None) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let src = source.as_bytes();
    if language == "go" {
        go(tree.root_node(), src, &mut out);
    } else {
        rust(
            tree.root_node(),
            src,
            &mut rust_module(path),
            false,
            &mut out,
        );
    }
    out
}

fn go(root: Node, src: &[u8], out: &mut Vec<Symbol>) {
    let mut cursor = root.walk();
    let package = root
        .named_children(&mut cursor)
        .find(|n| n.kind() == "package_clause")
        .and_then(|n| n.named_child(0))
        .map_or("", |n| text(n, src));
    for node in root.named_children(&mut cursor) {
        let Some(name) = node.child_by_field_name("name").map(|n| text(n, src)) else {
            continue;
        };
        match node.kind() {
            "function_declaration" => {
                push(out, node, format!("{package}.{name}"), Kind::Function, src)
            }
            "method_declaration" => {
                let receiver = node
                    .child_by_field_name("receiver")
                    .and_then(|r| r.named_child(0))
                    .and_then(|p| p.child_by_field_name("type"))
                    .map_or("", |t| text(base_type(t), src));
                push(
                    out,
                    node,
                    format!("{package}.{receiver}.{name}"),
                    Kind::Method,
                    src,
                );
            }
            _ => {}
        }
    }
}

fn rust(node: Node, src: &[u8], path: &mut Vec<String>, in_impl: bool, out: &mut Vec<Symbol>) {
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        let scope = match child.kind() {
            "function_item" => {
                if let Some(name) = child.child_by_field_name("name") {
                    let mut full = path.clone();
                    full.push(text(name, src).to_string());
                    let kind = if in_impl {
                        Kind::Method
                    } else {
                        Kind::Function
                    };
                    push(out, child, full.join("::"), kind, src);
                }
                continue;
            }
            "mod_item" | "trait_item" => child.child_by_field_name("name"),
            "impl_item" => child.child_by_field_name("type").map(base_type),
            _ => continue,
        };
        let (Some(scope), Some(body)) = (scope, child.child_by_field_name("body")) else {
            continue;
        };
        path.push(text(scope, src).to_string());
        rust(body, src, path, child.kind() != "mod_item", out);
        path.pop();
    }
}

fn base_type(node: Node) -> Node {
    match node.kind() {
        "pointer_type" | "reference_type" => node.named_child(0).map_or(node, base_type),
        "generic_type" => node.child_by_field_name("type").unwrap_or(node),
        _ => node,
    }
}

/// `src/auth/hash.rs` is `auth::hash`; `lib.rs`, `main.rs` and `mod.rs` name their directory.
fn rust_module(path: &str) -> Vec<String> {
    let rel = path.rsplit_once("src/").map_or(path, |(_, rest)| rest);
    let rel = rel.strip_suffix(".rs").unwrap_or(rel);
    let mut segments: Vec<String> = rel.split('/').map(str::to_string).collect();
    if matches!(
        segments.last().map(String::as_str),
        Some("lib" | "main" | "mod")
    ) {
        segments.pop();
    }
    segments
}

fn push(out: &mut Vec<Symbol>, node: Node, name: String, kind: Kind, src: &[u8]) {
    let mut calls = Vec::new();
    collect_calls(node, src, &mut calls);
    let name_node = node.child_by_field_name("name").unwrap_or(node);
    let at = name_node.start_position();
    let line_start = name_node.start_byte() - at.column;
    let column = std::str::from_utf8(&src[line_start..name_node.start_byte()])
        .map_or(at.column, |s| s.encode_utf16().count());
    out.push(Symbol {
        name,
        kind,
        start: node.start_position().row as u32 + 1,
        end: node.end_position().row as u32 + 1,
        name_at: (at.row as u32, column),
        calls,
    });
}

fn collect_calls(node: Node, src: &[u8], out: &mut Vec<Call>) {
    if node.kind() == "call_expression"
        && let Some(call) = node
            .child_by_field_name("function")
            .and_then(|f| callee(f, src))
    {
        out.push(call);
    }
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        collect_calls(child, src, out);
    }
}

fn callee(function: Node, src: &[u8]) -> Option<Call> {
    let simple = |n: Node| {
        matches!(n.kind(), "identifier" | "type_identifier" | "self")
            .then(|| text(n, src).to_string())
    };
    let (name, via) = match function.kind() {
        "identifier" => (function, Via::Plain),
        "selector_expression" => (
            function.child_by_field_name("field")?,
            Via::Receiver(function.child_by_field_name("operand").and_then(simple)),
        ),
        "field_expression" => (
            function.child_by_field_name("field")?,
            Via::Receiver(function.child_by_field_name("value").and_then(simple)),
        ),
        "scoped_identifier" => {
            let path = function.child_by_field_name("path")?;
            let last = match path.kind() {
                "scoped_identifier" => path.child_by_field_name("name")?,
                _ => base_type(path),
            };
            (
                function.child_by_field_name("name")?,
                Via::Path(text(last, src).to_string()),
            )
        }
        "generic_function" => return callee(function.child_by_field_name("function")?, src),
        _ => return None,
    };
    Some(Call {
        name: text(name, src).to_string(),
        via,
    })
}

fn text<'a>(node: Node, src: &'a [u8]) -> &'a str {
    node.utf8_text(src).unwrap_or("")
}
