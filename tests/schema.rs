//! The JSON Schema of the request contract (`contracts/request.schema.json`) beside the fixtures. No validator runs
//! here: the schema's objects are closed, so a member the validators take and the schema does not name is a request
//! the schema wrongly refuses. The test reads which members the schema names and compares them with the members the
//! valid fixtures carry, in both directions.

use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

type Members = BTreeSet<String>;

/// What every node may carry beside the members of its type.
const COMMON: [&str; 8] = [
    "type",
    "style",
    "if",
    "unless",
    "ifStale",
    "accessibility",
    "transition",
    "privacy",
];

fn schema() -> Value {
    serde_json::from_str(include_str!("../contracts/request.schema.json")).unwrap()
}

/// The names under `properties` at `pointer` of the schema.
fn named(schema: &Value, pointer: &str) -> Members {
    let properties = schema
        .pointer(pointer)
        .and_then(Value::as_object)
        .unwrap_or_else(|| panic!("the schema has no properties at {pointer}"));
    properties.keys().cloned().collect()
}

/// The members of each node type: the definitions whose `type` is one word.
fn node_members(schema: &Value) -> BTreeMap<String, Members> {
    let definitions = schema["$defs"].as_object().unwrap();
    definitions
        .values()
        .filter_map(|definition| {
            let properties = definition.get("properties")?.as_object()?;
            let kind = properties.get("type")?.get("const")?.as_str()?;
            Some((kind.to_owned(), properties.keys().cloned().collect()))
        })
        .collect()
}

/// Every start of a layout among the fixtures that the validators accept.
fn starts() -> Vec<Value> {
    let fixtures: Value =
        serde_json::from_str(include_str!("fixtures/layout-requests.json")).unwrap();
    let list = |group: &str, member: &str| -> Vec<Value> {
        let cases = fixtures[group].as_array().unwrap();
        cases.iter().map(|case| case[member].clone()).collect()
    };
    [
        list("valid", "input"),
        list("updates", "start"),
        list("ends", "start"),
    ]
    .concat()
    .into_iter()
    .filter(|input| input.get("layout").is_some())
    .collect()
}

/// Calls `each` with every node under `value`: an object whose `type` is a node type. The props of a custom node
/// are the app's own and hold no nodes.
fn nodes<'a>(
    value: &'a Value,
    kinds: &BTreeMap<String, Members>,
    each: &mut impl FnMut(&'a Value),
) {
    match value {
        Value::Object(members) => {
            let kind = members.get("type").and_then(Value::as_str);
            if kind.is_some_and(|kind| kinds.contains_key(kind)) {
                each(value);
            }
            for (name, member) in members {
                if name != "props" {
                    nodes(member, kinds, each);
                }
            }
        }
        Value::Array(items) => items.iter().for_each(|item| nodes(item, kinds, each)),
        _ => {}
    }
}

fn keys(value: &Value) -> Members {
    value.as_object().unwrap().keys().cloned().collect()
}

/// The schema names what the fixtures carry and nothing else: `carried` holds the members of each object of one
/// kind, by the fixture's place in the list.
fn agree(what: &str, named: &Members, carried: &[Members]) {
    assert!(!carried.is_empty(), "no valid fixture has {what}");
    let mut seen = Members::new();
    for members in carried {
        let unknown: Vec<_> = members.difference(named).collect();
        assert!(
            unknown.is_empty(),
            "the schema does not name {unknown:?} of {what}, which a valid fixture carries"
        );
        seen.extend(members.iter().cloned());
    }
    let unused: Vec<_> = named.difference(&seen).collect();
    assert!(
        unused.is_empty(),
        "the schema names {unused:?} of {what}, which no valid fixture carries"
    );
}

// AK-CONTRACT-14
#[test]
fn every_node_definition_names_the_common_members() {
    let kinds = node_members(&schema());
    assert_eq!(kinds.len(), 16, "{:?}", kinds.keys());
    for (kind, members) in &kinds {
        for common in COMMON {
            assert!(
                members.contains(common),
                "the schema's {kind} lacks {common}"
            );
        }
    }
}

// AK-CONTRACT-14
#[test]
fn the_schema_names_the_members_of_the_fixtures_nodes() {
    let schema = schema();
    let kinds = node_members(&schema);
    let starts = starts();
    assert!(starts.len() >= 200, "{}", starts.len());
    let mut of_kind: BTreeMap<&str, Vec<Members>> = BTreeMap::new();
    let mut accessibility = Vec::new();
    for start in &starts {
        nodes(&start["layout"], &kinds, &mut |node| {
            let kind = node["type"].as_str().unwrap();
            of_kind.entry(kind).or_default().push(keys(node));
            accessibility.extend(node.get("accessibility").map(keys));
        });
    }
    // The common members are checked on every definition; here a type answers for its own.
    let own = |members: &Members| -> Members {
        let common = |name: &&String| COMMON.contains(&name.as_str());
        members
            .iter()
            .filter(|name| !common(name))
            .cloned()
            .collect()
    };
    for (kind, named) in &kinds {
        let carried = of_kind.remove(kind.as_str()).unwrap_or_default();
        let unknown: BTreeSet<_> = carried
            .iter()
            .flat_map(|members| members.difference(named))
            .collect();
        assert!(
            unknown.is_empty(),
            "the schema does not name {unknown:?} of the node {kind}, which a valid fixture carries"
        );
        let carried: Vec<Members> = carried.iter().map(own).collect();
        agree(&format!("the node {kind}"), &own(named), &carried);
    }
    agree(
        "accessibility",
        &named(&schema, "/$defs/accessibility/properties"),
        &accessibility,
    );
}

// AK-CONTRACT-14
#[test]
fn the_schema_names_the_members_of_the_fixtures_layouts_and_styles() {
    let schema = schema();
    let starts = starts();
    let part = |pointer: &str| -> Vec<Members> {
        let found = starts.iter().filter_map(|start| start.pointer(pointer));
        found.map(keys).collect()
    };
    let layout = "/$defs/layout/properties";
    let island = format!("{layout}/island/properties");
    let style = "/$defs/style/properties";
    for (what, schema_at, fixture_at) in [
        ("a layout", layout.to_owned(), "/layout"),
        ("an island", island.clone(), "/layout/island"),
        (
            "an expanded island",
            format!("{island}/expanded/properties"),
            "/layout/island/expanded",
        ),
        (
            "the island's margins",
            format!("{island}/margins/properties"),
            "/layout/island/margins",
        ),
    ] {
        agree(what, &named(&schema, &schema_at), &part(fixture_at));
    }
    let styles: Vec<&Value> = starts
        .iter()
        .filter_map(|start| start.get("styles")?.as_object())
        .flat_map(|styles| styles.values())
        .collect();
    let frames = styles.iter().filter_map(|style| style.get("frame"));
    let frames: Vec<Members> = frames.map(keys).collect();
    let styles: Vec<Members> = styles.iter().map(|style| keys(style)).collect();
    agree("a style", &named(&schema, style), &styles);
    agree(
        "a frame",
        &named(&schema, &format!("{style}/frame/properties")),
        &frames,
    );
}
