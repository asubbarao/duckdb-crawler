//! Hydration state extraction from SPA frameworks
//!
//! Extracts embedded application state from:
//! - Next.js: `<script id="__NEXT_DATA__" type="application/json">`
//! - Nuxt/Vue: `window.__NUXT__={...}`, `window.__pinia={...}`
//! - Apollo: `window.__APOLLO_STATE__={...}`
//! - Generic: `<script type="application/json">` blocks
//!
//! Also handles devalue/Pinia serialization format deserialization.

use scraper::{Html, Selector};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// Extract all hydration state from an HTML document.
/// Returns a map of key -> JSON value.
pub fn extract_hydration_state(document: &Html) -> HashMap<String, Value> {
    let mut result = HashMap::new();

    // Strategy A: JSON script blocks (Next.js, Drupal, generic)
    extract_json_scripts(document, &mut result);

    // Strategy B: window.X assignments (Nuxt, Pinia, Apollo, dataLayer)
    extract_window_assignments(document, &mut result);

    // Post-process: try devalue deserialization on array values
    let keys: Vec<String> = result.keys().cloned().collect();
    for key in keys {
        if let Some(Value::Array(arr)) = result.get(&key) {
            if is_devalue_format(arr) {
                if let Some(deserialized) = deserialize_devalue(arr) {
                    result.insert(key, deserialized);
                }
            }
        }
    }

    result
}

/// Strategy A: Extract `<script type="application/json">` blocks.
/// Key is the `id` attribute, or first `data-*` attribute, or "anonymous".
pub fn extract_json_scripts(document: &Html, result: &mut HashMap<String, Value>) {
    let selector = match Selector::parse(r#"script[type="application/json"]"#) {
        Ok(s) => s,
        Err(_) => return,
    };

    for element in document.select(&selector) {
        let el = element.value();

        // Determine the key from id or data-* attributes
        let key = if let Some(id) = el.id() {
            id.to_string()
        } else {
            // Find first data-* attribute
            el.attrs()
                .find(|(name, _)| name.starts_with("data-"))
                .map(|(_, val)| val.to_string())
                .unwrap_or_else(|| "anonymous".to_string())
        };

        let text: String = element.text().collect();
        let trimmed = text.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Parse as strict JSON
        if let Ok(val) = serde_json::from_str(trimmed) {
            result.insert(key, val);
        }
    }
}

/// Strategy B: Extract `window.X = {...}` assignments from script tags.
/// Uses tree-sitter for error-tolerant JS parsing.
pub fn extract_window_assignments(document: &Html, result: &mut HashMap<String, Value>) {
    let selector =
        match Selector::parse("script:not([type]), script[type='text/javascript']") {
            Ok(s) => s,
            Err(_) => return,
        };

    let mut parser = tree_sitter::Parser::new();
    if parser
        .set_language(&tree_sitter_javascript::LANGUAGE.into())
        .is_err()
    {
        return;
    }

    for element in document.select(&selector) {
        let raw_text: String = element.text().collect();
        if raw_text.trim().is_empty() {
            continue;
        }

        // Decode HTML entities (Pinia/Vue SSR encodes with &quot; etc.)
        let text = if raw_text.contains("&quot;")
            || raw_text.contains("&amp;")
            || raw_text.contains("&lt;")
        {
            match htmlescape::decode_html(&raw_text) {
                Ok(decoded) => decoded,
                Err(_) => raw_text,
            }
        } else {
            raw_text
        };

        let tree = match parser.parse(text.as_bytes(), None) {
            Some(t) => t,
            None => continue,
        };

        extract_assignments_from_tree(&text, tree.root_node(), result);
    }
}

/// Walk a tree-sitter parse tree to find assignment expressions.
/// Extracts: `window.X = value`, `var X = value`, `X = value`
pub fn extract_assignments_from_tree(
    source: &str,
    node: tree_sitter::Node,
    result: &mut HashMap<String, Value>,
) {
    let mut cursor = node.walk();

    for child in node.children(&mut cursor) {
        match child.kind() {
            // var X = value, let X = value, const X = value
            "lexical_declaration" | "variable_declaration" => {
                extract_from_var_declaration(source, child, result);
            }
            // X = value (expression_statement containing assignment_expression)
            "expression_statement" => {
                if let Some(expr) = child.named_child(0) {
                    if expr.kind() == "assignment_expression" {
                        extract_from_assignment(source, expr, result);
                    }
                }
            }
            // Recurse into other statement-level nodes
            _ => {
                extract_assignments_from_tree(source, child, result);
            }
        }
    }
}

/// Extract from `var/let/const X = value`
fn extract_from_var_declaration(
    source: &str,
    node: tree_sitter::Node,
    result: &mut HashMap<String, Value>,
) {
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if child.kind() == "variable_declarator" {
            let name_node = child.child_by_field_name("name");
            let value_node = child.child_by_field_name("value");

            if let (Some(name), Some(value)) = (name_node, value_node) {
                if name.kind() == "identifier" {
                    let var_name = &source[name.byte_range()];
                    if let Some(json_val) = parse_js_value(source, value) {
                        result.insert(var_name.to_string(), json_val);
                    }
                }
            }
        }
    }
}

/// Extract from `X = value` or `window.X = value`
fn extract_from_assignment(
    source: &str,
    node: tree_sitter::Node,
    result: &mut HashMap<String, Value>,
) {
    let left = node.child_by_field_name("left");
    let right = node.child_by_field_name("right");

    let (left, right) = match (left, right) {
        (Some(l), Some(r)) => (l, r),
        _ => return,
    };

    let key = match left.kind() {
        // Simple: X = value
        "identifier" => {
            let name = &source[left.byte_range()];
            Some(name.to_string())
        }
        // Member: window.X = value, window["X"] = value, self.X = value
        "member_expression" => extract_member_key(source, left),
        _ => None,
    };

    if let Some(key) = key {
        if let Some(json_val) = parse_js_value(source, right) {
            result.insert(key, json_val);
        }
    }
}

/// Extract key from member expression like `window.__NEXT_DATA__` or `window["__pinia"]`
fn extract_member_key(source: &str, node: tree_sitter::Node) -> Option<String> {
    let object = node.child_by_field_name("object")?;
    let property = node.child_by_field_name("property")?;

    let obj_name = &source[object.byte_range()];

    // Only extract from window.X or self.X
    if obj_name != "window" && obj_name != "self" && obj_name != "globalThis" {
        return None;
    }

    match property.kind() {
        "property_identifier" => {
            let prop = &source[property.byte_range()];
            Some(prop.to_string())
        }
        // window["__pinia"] — computed property with string literal
        "string" | "string_fragment" => {
            let prop = &source[property.byte_range()];
            // Strip quotes
            let trimmed = prop.trim_matches(|c| c == '"' || c == '\'');
            Some(trimmed.to_string())
        }
        _ => None,
    }
}

/// Parse a tree-sitter JS value node into serde_json::Value.
/// Extracts the source text and parses with json5 (handles unquoted keys, trailing commas).
pub fn parse_js_value(source: &str, node: tree_sitter::Node) -> Option<Value> {
    let text = &source[node.byte_range()];

    match node.kind() {
        "string" => {
            // JS string literal → remove quotes, parse as JSON string
            let inner = text.trim_matches(|c| c == '"' || c == '\'');
            Some(Value::String(inner.to_string()))
        }
        "number" => {
            if let Ok(n) = text.parse::<i64>() {
                Some(Value::Number(n.into()))
            } else if let Ok(n) = text.parse::<f64>() {
                serde_json::Number::from_f64(n).map(Value::Number)
            } else {
                None
            }
        }
        "true" => Some(Value::Bool(true)),
        "false" => Some(Value::Bool(false)),
        "null" => Some(Value::Null),
        "undefined" => Some(Value::Null),
        "object" | "array" => {
            // Use json5 to parse JS object/array literals (handles unquoted keys, trailing commas)
            json5::from_str(text).ok()
        }
        // JSON.parse("...") — extract the string argument and parse it
        "call_expression" => {
            parse_json_parse_call(source, node)
        }
        // For other expressions, try json5 as a last resort
        _ => json5::from_str(text).ok(),
    }
}

/// Handle JSON.parse("...") call expressions.
/// Extracts the string argument, unescapes it, and parses as JSON.
fn parse_json_parse_call(source: &str, node: tree_sitter::Node) -> Option<Value> {
    // Check if this is JSON.parse(...)
    let func = node.child_by_field_name("function")?;
    let func_text = &source[func.byte_range()];
    if func_text != "JSON.parse" {
        return None;
    }

    // Get the arguments node
    let args = node.child_by_field_name("arguments")?;

    // Find the first string argument and use serde_json to properly unescape it
    let mut cursor = args.walk();
    for child in args.children(&mut cursor) {
        if child.kind() == "string" {
            let raw = &source[child.byte_range()];
            // The raw text is a JS string literal like "..." or '...'
            // serde_json can parse double-quoted JSON strings with proper escape handling
            if raw.starts_with('"') {
                // Parse the string literal to get the unescaped content
                if let Ok(Value::String(unescaped)) = serde_json::from_str(raw) {
                    // Now parse the unescaped content as JSON
                    return serde_json::from_str(&unescaped).ok();
                }
            } else if raw.starts_with('\'') {
                // Single-quoted: convert to double-quoted for serde_json
                let inner = &raw[1..raw.len().saturating_sub(1)];
                let double_quoted = format!("\"{}\"", inner);
                if let Ok(Value::String(unescaped)) = serde_json::from_str(&double_quoted) {
                    return serde_json::from_str(&unescaped).ok();
                }
            }
        }
    }
    None
}

/// Check if a JSON array looks like devalue format.
/// Devalue format: first element is an object, and its values are small integers
/// that serve as indices into the flat array.
fn is_devalue_format(arr: &[Value]) -> bool {
    if arr.len() < 2 {
        return false;
    }

    // First element should be an object
    let first = match &arr[0] {
        Value::Object(obj) => obj,
        _ => return false,
    };

    if first.is_empty() {
        return false;
    }

    // Check that most values in the first object are small integers (indices)
    let mut index_count = 0;
    let mut total = 0;
    for val in first.values() {
        total += 1;
        if let Value::Number(n) = val {
            if let Some(i) = n.as_u64() {
                if (i as usize) < arr.len() {
                    index_count += 1;
                }
            }
        }
    }

    // At least 50% of values should be valid indices
    total > 0 && index_count * 2 >= total
}

/// Deserialize a devalue-format flat array into a normal nested JSON value.
/// Format: `[root_object, value1, value2, ...]` where integer values in objects
/// are indices into the flat array.
///
/// Reference: https://github.com/sveltejs/devalue
fn deserialize_devalue(flat: &[Value]) -> Option<Value> {
    if flat.is_empty() {
        return None;
    }
    let mut visited = HashSet::new();
    resolve_value(flat, 0, &mut visited)
}

fn resolve_value(flat: &[Value], index: usize, visited: &mut HashSet<usize>) -> Option<Value> {
    if index >= flat.len() {
        return None;
    }

    // Cycle detection
    if !visited.insert(index) {
        return Some(Value::Null); // Break cycle
    }

    let result = match &flat[index] {
        Value::Object(obj) => {
            let mut resolved = serde_json::Map::new();
            for (key, val) in obj {
                let resolved_val = match val {
                    Value::Number(n) if n.as_u64().is_some() => {
                        let idx = n.as_u64().unwrap() as usize;
                        if idx < flat.len() {
                            resolve_value(flat, idx, visited)
                                .unwrap_or(Value::Null)
                        } else {
                            val.clone()
                        }
                    }
                    _ => val.clone(),
                };
                resolved.insert(key.clone(), resolved_val);
            }
            Some(Value::Object(resolved))
        }
        Value::Array(arr) => {
            let mut resolved = Vec::new();
            for val in arr {
                let resolved_val = match val {
                    Value::Number(n) if n.as_u64().is_some() => {
                        let idx = n.as_u64().unwrap() as usize;
                        if idx < flat.len() {
                            resolve_value(flat, idx, visited)
                                .unwrap_or(Value::Null)
                        } else {
                            val.clone()
                        }
                    }
                    _ => val.clone(),
                };
                resolved.push(resolved_val);
            }
            Some(Value::Array(resolved))
        }
        // Primitive values are returned as-is
        other => Some(other.clone()),
    };

    visited.remove(&index);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_devalue_simple() {
        // [{"message":1},"hello"] → {"message":"hello"}
        let flat: Vec<Value> = serde_json::from_str(r#"[{"message":1},"hello"]"#).unwrap();
        let result = deserialize_devalue(&flat).unwrap();
        assert_eq!(result, serde_json::json!({"message": "hello"}));
    }

    #[test]
    fn test_devalue_nested() {
        // [{"name":1,"price":2},"Mozzarella",1.99]
        let flat: Vec<Value> =
            serde_json::from_str(r#"[{"name":1,"price":2},"Mozzarella",1.99]"#).unwrap();
        let result = deserialize_devalue(&flat).unwrap();
        assert_eq!(
            result,
            serde_json::json!({"name": "Mozzarella", "price": 1.99})
        );
    }

    #[test]
    fn test_devalue_cycle() {
        // [{"self":0}] → {"self": null} (cycle broken)
        let flat: Vec<Value> = serde_json::from_str(r#"[{"self":0}]"#).unwrap();
        let result = deserialize_devalue(&flat).unwrap();
        assert_eq!(result, serde_json::json!({"self": null}));
    }

    #[test]
    fn test_not_devalue() {
        // Regular array, not devalue format
        let arr = vec![Value::String("hello".into()), Value::Number(42.into())];
        assert!(!is_devalue_format(&arr));
    }

    #[test]
    fn test_extract_json_scripts() {
        let html = Html::parse_document(
            r#"<html><head>
            <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"name":"test"}}}</script>
            </head><body></body></html>"#,
        );
        let mut result = HashMap::new();
        extract_json_scripts(&html, &mut result);
        assert!(result.contains_key("__NEXT_DATA__"));
        let data = &result["__NEXT_DATA__"];
        assert_eq!(
            data.pointer("/props/pageProps/name").unwrap(),
            &Value::String("test".into())
        );
    }

    #[test]
    fn test_extract_window_assignment() {
        let html = Html::parse_document(
            r#"<html><body>
            <script>window.__INITIAL_STATE__ = {"user": "test", "count": 42};</script>
            </body></html>"#,
        );
        let mut result = HashMap::new();
        extract_window_assignments(&html, &mut result);
        assert!(result.contains_key("__INITIAL_STATE__"));
    }

    #[test]
    fn test_extract_var_declaration() {
        let html = Html::parse_document(
            r#"<html><body>
            <script>var dataLayer = [{"event": "pageview"}];</script>
            </body></html>"#,
        );
        let mut result = HashMap::new();
        extract_window_assignments(&html, &mut result);
        assert!(result.contains_key("dataLayer"));
    }

    #[test]
    fn test_html_entity_decode() {
        let html = Html::parse_document(
            r#"<html><body>
            <script>window.__data = {&quot;name&quot;: &quot;test&quot;};</script>
            </body></html>"#,
        );
        let mut result = HashMap::new();
        extract_window_assignments(&html, &mut result);
        assert!(result.contains_key("__data"));
    }
}
