//! The shared fixtures of request contract v2 through the Rust validator. The Swift tests (`tests/swift/run.sh`) put
//! the same file through the Swift validator and the bridge; both must give each case its stated verdict, code and
//! weight.

use activitykit::contract::{
    EndInput, LayoutStartInput, LayoutUpdateInput, Validate, validate_request, weight,
};
use serde_json::{Value, json};

fn cases(verdict: &str) -> Vec<Value> {
    let fixtures: Value =
        serde_json::from_str(include_str!("fixtures/layout-requests.json")).unwrap();
    fixtures[verdict].as_array().unwrap().clone()
}

fn code(result: activitykit::Result<()>) -> Option<&'static str> {
    result.err().map(|error| error.code())
}

/// Weight of a start (layout, styles, values) or an update (values) as the fixtures state it.
fn layout_weight(input: &Value) -> usize {
    let part = |pointer| input.pointer(pointer).map(weight);
    part("/snapshot/values").unwrap()
        + part("/layout").map_or(0, |layout| layout + part("/styles").unwrap_or(2))
}

// AK-CONTRACT-1, AK-CONTRACT-12, AK-END-7, AK-START-5, AK-ACCESS-2, AK-LINK-2, AK-LINK-3,
// AK-MOTION-1, AK-MOTION-2, AK-PRIVACY-1, AK-ISLAND-1, AK-ISLAND-2
#[test]
fn every_fixture_gets_its_verdict_code_and_weight() {
    let (valid, invalid) = (cases("valid"), cases("invalid"));
    assert!(
        valid.len() >= 200 && invalid.len() >= 800,
        "{} {}",
        valid.len(),
        invalid.len()
    );
    for case in &valid {
        let (name, command) = (&case["name"], case["command"].as_str().unwrap());
        assert_eq!(
            code(validate_request(command, case["input"].clone())),
            None,
            "{name}"
        );
        match command {
            // An end states the weight of its final values when it has them.
            "end_layout" if case["input"].get("snapshot").is_none() => {
                assert!(case.get("weight").is_none(), "{name}")
            }
            _ => assert_eq!(
                case["weight"],
                json!(layout_weight(&case["input"])),
                "{name}"
            ),
        }
    }
    for case in &invalid {
        let (name, command) = (&case["name"], case["command"].as_str().unwrap());
        let verdict = code(validate_request(command, case["input"].clone()));
        assert_eq!(verdict, case["code"].as_str(), "{name}");
    }
}

// AK-CONTRACT-4, AK-UPDATE-6, AK-LINK-4
/// Each pair is a start and the update after it, which the Swift layer checks against the stored layout and styles.
#[test]
fn every_update_fixture_is_checked_against_its_start() {
    let updates = cases("updates");
    assert!(updates.len() >= 30);
    for case in &updates {
        let name = case["name"].as_str().unwrap();
        assert_eq!(
            code(validate_request("start_layout", case["start"].clone())),
            None,
            "{name}"
        );
        let start: LayoutStartInput = serde_json::from_value(case["start"].clone()).unwrap();
        let verdict = validate_request("update_layout", case["update"].clone()).and_then(|()| {
            let update: LayoutUpdateInput = serde_json::from_value(case["update"].clone()).unwrap();
            start.validate_update(&update)
        });
        match case.get("code") {
            None => {
                assert_eq!(code(verdict), None, "{name}");
                let stored =
                    layout_weight(&case["start"]) - weight(&case["start"]["snapshot"]["values"]);
                let total = stored + weight(&case["update"]["snapshot"]["values"]);
                assert_eq!(case["weight"], json!(total), "{name}");
            }
            Some(expected) => assert_eq!(code(verdict), expected.as_str(), "{name}"),
        }
    }
}

// AK-CONTRACT-1
#[test]
fn valid_fixtures_keep_their_verdict_and_weight_through_the_typed_models() {
    for case in cases("valid") {
        let (name, input) = (&case["name"], case["input"].clone());
        let encoded = match case["command"].as_str().unwrap() {
            "start_layout" => {
                let typed: LayoutStartInput = serde_json::from_value(input).unwrap();
                assert_eq!(code(typed.validate()), None, "{name}");
                serde_json::to_value(&typed).unwrap()
            }
            "update_layout" => {
                let typed: LayoutUpdateInput = serde_json::from_value(input).unwrap();
                assert_eq!(code(typed.validate()), None, "{name}");
                serde_json::to_value(&typed).unwrap()
            }
            _ => continue,
        };
        assert_eq!(case["weight"], json!(layout_weight(&encoded)), "{name}");
    }
}

// AK-ERROR-2, AK-START-6
#[test]
fn the_weight_limit_is_a_payload_error_only_for_an_otherwise_valid_request() {
    let start = |values: Value| {
        json!({"activityKey":"job:1","schemaVersion":2,"fallback":"none",
            "layout":{"lockScreen":{"type":"text","bind":"a"}},"snapshot":{"revision":0,"values":values}})
    };
    let heavy =
        json!({"a":"x".repeat(1000),"b":"x".repeat(1000),"c":"x".repeat(1000),"d":"x".repeat(600)});
    let error = validate_request("start_layout", start(heavy.clone())).unwrap_err();
    assert_eq!(error.code(), "PAYLOAD_TOO_LARGE");
    assert!(!error.message().contains("xx"));
    let update = json!({"id":"id","snapshot":{"revision":1,"values":heavy}});
    assert_eq!(
        code(validate_request("update_layout", update)),
        Some("PAYLOAD_TOO_LARGE")
    );
    let mut broken = start(
        json!({"b":"x".repeat(1000),"c":"x".repeat(1000),"d":"x".repeat(1000),"e":"x".repeat(1000)}),
    );
    assert_eq!(
        code(validate_request("start_layout", broken.clone())),
        Some("INVALID_INPUT")
    );
    broken["layout"]["lockScreen"] = json!({"type":"text","value":"a"});
    assert_eq!(
        code(validate_request("start_layout", broken)),
        Some("PAYLOAD_TOO_LARGE")
    );
}

// AK-CONTRACT-5
#[test]
fn only_the_v2_commands_are_taken() {
    let v2 = json!({"activityKey":"job:1","schemaVersion":2,"fallback":"none",
        "layout":{"lockScreen":{"type":"text","value":"a"}},"snapshot":{"revision":0,"values":{}}});
    assert_eq!(code(validate_request("start_layout", v2.clone())), None);
    let end = json!({"id":"id","policy":{"kind":"after","at":1}});
    assert_eq!(code(validate_request("end_layout", end)), None);
    for command in [
        "start",
        "update",
        "end",
        "list_layout",
        "startLayout",
        "start_layout ",
        "",
    ] {
        assert_eq!(
            code(validate_request(command, v2.clone())),
            Some("INVALID_INPUT"),
            "{command}"
        );
    }
}

// AK-CONTRACT-11
/// A request read from JSON text keeps every number as the double that was written.
#[test]
fn numbers_keep_their_value_when_read_from_json_text() {
    let start = |style: &str, values: &str| {
        let text = format!(
            r#"{{"activityKey":"job:1","schemaVersion":2,"fallback":"none","layout":{{"lockScreen":
            {{"type":"vstack","children":[{{"type":"text","value":"a","style":"s"}},
            {{"type":"timerText","start":"from","end":"to"}}]}}}},"styles":{{"s":{style}}},
            "snapshot":{{"revision":0,"values":{values}}}}}"#
        );
        code(validate_request(
            "start_layout",
            serde_json::from_str(&text).unwrap(),
        ))
    };
    let times = r#"{"from":1,"to":2}"#;
    assert_eq!(
        start(r#"{"size":96,"minimumScaleFactor":0.1}"#, times),
        None
    );
    // Each number is just outside its range; a rounded read would bring it back inside.
    for (style, values) in [
        (r#"{"size":96.00000000000001}"#, times),
        (r#"{"minimumScaleFactor":0.09999999999999999}"#, times),
        (r#"{"size":12}"#, r#"{"from":0.9999999999999999,"to":2}"#),
        (
            r#"{"size":12}"#,
            r#"{"from":3875413157790899.5,"to":3875413157790901}"#,
        ),
        (r#"{"size":12}"#, r#"{"from":1,"to":8640000000000000.6}"#),
    ] {
        assert_eq!(
            start(style, values),
            Some("INVALID_INPUT"),
            "{style} {values}"
        );
    }
}

// AK-CONTRACT-12, AK-END-6, AK-LINK-4
/// Each pair is a start and an end with final content, which the Swift layer checks as it checks an update.
#[test]
fn every_end_fixture_is_checked_against_its_start() {
    let ends = cases("ends");
    assert!(ends.len() >= 4);
    for case in &ends {
        let name = case["name"].as_str().unwrap();
        let start: LayoutStartInput = serde_json::from_value(case["start"].clone()).unwrap();
        let verdict = validate_request("end_layout", case["end"].clone()).and_then(|()| {
            let end: EndInput = serde_json::from_value(case["end"].clone()).unwrap();
            start.validate_end(&end)
        });
        match case.get("code") {
            None => {
                assert_eq!(code(verdict), None, "{name}");
                let stored =
                    layout_weight(&case["start"]) - weight(&case["start"]["snapshot"]["values"]);
                let total = stored + weight(&case["end"]["snapshot"]["values"]);
                assert_eq!(case["weight"], json!(total), "{name}");
            }
            Some(expected) => assert_eq!(code(verdict), expected.as_str(), "{name}"),
        }
    }
    // An end without final content is checked against the start alone.
    let start: LayoutStartInput = serde_json::from_value(ends[0]["start"].clone()).unwrap();
    let plain: EndInput =
        serde_json::from_value(json!({"id":"opaque-handle-1","policy":{"kind":"default"}}))
            .unwrap();
    assert_eq!(code(start.validate_end(&plain)), None);
}

/// Every string value in `value`, at any depth.
fn strings(value: &Value) -> Vec<&str> {
    match value {
        Value::String(text) => vec![text.as_str()],
        Value::Array(items) => items.iter().flat_map(strings).collect(),
        Value::Object(members) => members.values().flat_map(strings).collect(),
        _ => Vec::new(),
    }
}

// AK-ERROR-2
/// An error's message is one of a few constant texts: it never repeats what the request held.
#[test]
fn every_fixture_error_is_a_constant_text() {
    let mut messages = std::collections::BTreeSet::new();
    for case in cases("invalid") {
        let (name, command) = (&case["name"], case["command"].as_str().unwrap());
        let error = validate_request(command, case["input"].clone()).unwrap_err();
        let message = error.message();
        for text in strings(&case["input"]) {
            assert!(
                text.chars().count() < 4 || !message.contains(text),
                "{name}: {message} repeats {text}"
            );
        }
        messages.insert(message.to_owned());
    }
    assert!(messages.len() <= 4, "{messages:?}");
}
