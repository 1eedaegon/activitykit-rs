//! The JSON Schema of the request contract (`contracts/request.schema.json`), run by a validator against the fixtures.
//! A schema says less than the validators in Rust and Swift: it knows no weight, no limit across a tree and no value
//! that a reference names. So every valid fixture must be valid for it, and of the invalid ones it refuses those
//! that are invalid by their shape. `fixtures/beyond-the-schema.json` names the others, one by one: the line between
//! the two is written down, and a change of the schema that moves it shows here.

use serde_json::{Value, json};
use std::collections::BTreeSet;

fn read(text: &str) -> Value {
    serde_json::from_str(text).expect("JSON")
}

fn schema() -> jsonschema::Validator {
    let schema = read(include_str!("../contracts/request.schema.json"));
    jsonschema::validator_for(&schema).expect("the schema is a JSON Schema of its draft")
}

fn layouts() -> Value {
    read(include_str!("fixtures/layout-requests.json"))
}

fn cases(file: &Value, group: &str) -> Vec<Value> {
    file[group].as_array().expect("a list of cases").clone()
}

fn name(case: &Value) -> &str {
    case["name"].as_str().expect("a case has a name")
}

/// A request as the schema takes it: the command with its input.
fn request(command: &str, input: &Value) -> Value {
    json!({ "command": command, "input": input })
}

/// The request of a case that states its own command.
fn stated(case: &Value) -> Value {
    request(case["command"].as_str().expect("a command"), &case["input"])
}

/// The second request of each pair of `updates` and `ends`, under the command it is sent with.
const PAIRS: [(&str, &str, &str); 2] = [
    ("updates", "update", "update_layout"),
    ("ends", "end", "end_layout"),
];

// AK-CONTRACT-15
#[test]
fn every_valid_fixture_is_valid_for_the_schema() {
    let (schema, file) = (schema(), layouts());
    let valid = cases(&file, "valid");
    assert!(valid.len() >= 200, "{}", valid.len());
    for case in &valid {
        assert!(schema.is_valid(&stated(case)), "{}", name(case));
    }
    for (group, member, command) in PAIRS {
        for case in cases(&file, group) {
            let start = request("start_layout", &case["start"]);
            assert!(schema.is_valid(&start), "the start of {}", name(&case));
            // A pair without a code is a request that every layer accepts.
            if case.get("code").is_none() {
                let second = request(command, &case[member]);
                assert!(schema.is_valid(&second), "{}", name(&case));
            }
        }
    }
}

// AK-CONTRACT-15
#[test]
fn the_schema_refuses_an_invalid_fixture_unless_it_is_listed_as_beyond_it() {
    let (schema, file) = (schema(), layouts());
    let listed: Vec<String> =
        serde_json::from_str(include_str!("fixtures/beyond-the-schema.json")).expect("names");
    assert!(
        listed.windows(2).all(|pair| pair[0] < pair[1]),
        "the list is sorted and names a fixture once"
    );
    let beyond: BTreeSet<&str> = listed.iter().map(String::as_str).collect();

    let mut invalid: Vec<(String, Value)> = cases(&file, "invalid")
        .iter()
        .map(|case| (name(case).to_owned(), stated(case)))
        .collect();
    for (group, member, command) in PAIRS {
        let refused = cases(&file, group);
        let refused = refused.iter().filter(|case| case.get("code").is_some());
        invalid
            .extend(refused.map(|case| (name(case).to_owned(), request(command, &case[member]))));
    }
    for (name, request) in &invalid {
        let verdict = if schema.is_valid(request) {
            "accepts"
        } else {
            "refuses"
        };
        let expected = if beyond.contains(name.as_str()) {
            "accepts"
        } else {
            "refuses"
        };
        assert_eq!(verdict, expected, "the schema {verdict} \"{name}\"");
    }
    let names: BTreeSet<&str> = invalid.iter().map(|(name, _)| name.as_str()).collect();
    let gone: Vec<_> = beyond.difference(&names).collect();
    assert!(gone.is_empty(), "the list names no fixture: {gone:?}");
    // Both kinds are there: the schema is neither empty nor the whole contract.
    assert!(beyond.len() >= 100 && names.len() - beyond.len() >= 500);
}

// AK-CONTRACT-15
#[test]
fn the_schema_decides_the_requests_of_contract_v1() {
    let schema = schema();
    let file = read(include_str!("fixtures/v1-requests.json"));
    let mut commands = BTreeSet::new();
    for (group, expected) in [("valid", true), ("invalid", false)] {
        let cases = cases(&file, group);
        assert!(cases.len() >= 10, "{group}: {}", cases.len());
        for case in &cases {
            assert_eq!(schema.is_valid(&stated(case)), expected, "{}", name(case));
            commands.insert((group, case["command"].as_str().unwrap().to_owned()));
        }
    }
    // Each command of contract v1 is tried with a request the schema takes and with one it refuses.
    for command in ["start", "update", "end"] {
        for group in ["valid", "invalid"] {
            assert!(
                commands.contains(&(group, command.to_owned())),
                "{group} {command}"
            );
        }
    }
}
