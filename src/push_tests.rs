//! The payloads a server sends: their shape, their checks and the headers that go with them.

use crate::{
    Alert, Bound, Error, Layout, Style, Value, Values,
    layout::{button, hstack, progress, symbol, text, vstack},
    push::{MAX_PAYLOAD_BYTES, PRIORITY_LOW, PRIORITY_NOW, PUSH_TYPE, Payload, topic},
    values,
};
use serde_json::{Value as Json, json};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn at(millis: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(millis)
}

fn sketch() -> Layout {
    Layout::new(vstack([
        hstack([
            symbol("mic.fill"),
            text("Recording").style("status"),
            button("stop", text("Stop")),
        ]),
        progress("level"),
    ]))
    .style("status", Style::new().color(Bound::key("tone")))
}

fn first() -> Values {
    values! { "tone" => "green", "level" => 0.1 }
}

/// The three payloads the Swift host test decodes as the widget would (`tests/fixtures/push-payloads.json`).
fn fixtures() -> Json {
    let update = Payload::update(values! { "tone" => "red", "level" => 0.5 })
        .revision(3)
        .timestamp(at(1_700_000_000_000))
        .stale_at(at(1_700_000_600_000))
        .relevance(80.0)
        .alert(Alert::new("Louder", "The level rose"))
        .sent_at(at(1_700_000_001_000));
    let end = Payload::end()
        .dismiss_at(at(1_700_003_600_000))
        .sent_at(at(1_700_000_002_000));
    let start = Payload::start("la-ios-layout-push-1", "pushed", sketch(), first())
        .alert(Alert::new("Recording", "Tap to look"))
        .input_push_token()
        .sent_at(at(1_700_000_003_000));
    json!({
        "update": update.to_value().unwrap(),
        "end": end.to_value().unwrap(),
        "start": start.to_value().unwrap(),
    })
}

// AK-PUSH-9
#[test]
fn an_update_payload_carries_the_snapshot_and_the_alert() {
    let payload = fixtures()["update"].clone();
    assert_eq!(
        payload,
        json!({"aps": {
            "timestamp": 1_700_000_001u64,
            "event": "update",
            "content-state": {
                "revision": 3,
                "values": {"tone": "red", "level": 0.5},
                "timestamp": 1_700_000_000_000u64,
                "staleAt": 1_700_000_600_000u64
            },
            "alert": {"title": "Louder", "body": "The level rose"},
            "stale-date": 1_700_000_600u64,
            "relevance-score": 80.0
        }})
    );
    // Without options: the snapshot alone, sent now.
    let plain: Json = serde_json::from_str(
        &Payload::update(values! { "tone" => "red", "level" => 0.5 })
            .revision(1)
            .to_json()
            .unwrap(),
    )
    .unwrap();
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let sent = plain["aps"]["timestamp"].as_u64().unwrap();
    assert!(
        now - 5 <= sent && sent <= now + 5,
        "sent at {sent}, now {now}"
    );
    assert_eq!(
        plain["aps"]["content-state"],
        json!({"revision": 1, "values": {"tone": "red", "level": 0.5}})
    );
    assert_eq!(plain["aps"].get("alert"), None);
    assert_eq!(plain["aps"].get("stale-date"), None);
}

// AK-PUSH-9
#[test]
fn an_end_payload_names_its_dismissal() {
    assert_eq!(
        fixtures()["end"],
        json!({"aps": {"timestamp": 1_700_000_002u64, "event": "end", "dismissal-date": 1_700_003_600u64}})
    );
    // An end with final content carries it like an update.
    let with_content = Payload::end_with(values! { "tone" => "gray", "level" => 1.0 })
        .revision(9)
        .sent_at(at(1_700_000_002_000))
        .to_value()
        .unwrap();
    assert_eq!(
        with_content["aps"]["content-state"],
        json!({"revision": 9, "values": {"tone": "gray", "level": 1.0}})
    );
    assert_eq!(with_content["aps"]["event"], "end");
}

// AK-PUSH-10
#[test]
fn a_start_payload_carries_the_attributes_the_widget_reads() {
    let payload = fixtures()["start"].clone();
    let aps = &payload["aps"];
    assert_eq!(aps["timestamp"], 1_700_000_003u64);
    assert_eq!(aps["event"], "start");
    assert_eq!(aps["attributes-type"], "LiveActivityLayoutAttributes");
    assert_eq!(aps["input-push-token"], 1);
    assert_eq!(
        aps["alert"],
        json!({"title": "Recording", "body": "Tap to look"})
    );
    assert_eq!(
        aps["content-state"],
        json!({"revision": 0, "values": {"tone": "green", "level": 0.1}})
    );
    let attributes = &aps["attributes"];
    assert_eq!(attributes["instanceID"], "la-ios-layout-push-1");
    assert_eq!(attributes["activityKey"], "pushed");
    assert_eq!(attributes["schemaVersion"], 2);
    assert_eq!(attributes["fallback"], "none");
    let fingerprint = attributes["initialFingerprint"].as_str().unwrap();
    assert!(
        fingerprint.len() == 64 && fingerprint.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "a SHA-256 in hex: {fingerprint}"
    );
    let (regions, styles) = sketch().into_wire();
    assert_eq!(
        attributes["document"]["layout"],
        serde_json::to_value(regions).unwrap()
    );
    assert_eq!(
        attributes["document"].get("styles").cloned(),
        styles.map(|styles| serde_json::to_value(styles).unwrap())
    );
    // The system shows a started activity with its alert: a start without one is refused here.
    let silent = Payload::start("la-ios-layout-push-2", "pushed", sketch(), first()).to_json();
    assert!(matches!(silent, Err(Error::InvalidInput(_))), "{silent:?}");
    // The payloads the Swift host test reads are these: `UPDATE_FIXTURES=1 cargo test push_tests` writes them.
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/push-payloads.json"
    );
    if std::env::var_os("UPDATE_FIXTURES").is_some() {
        let text = serde_json::to_string_pretty(&fixtures()).unwrap() + "\n";
        std::fs::write(path, text).unwrap();
    }
    let committed: Json = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    assert_eq!(
        fixtures(),
        committed,
        "tests/fixtures/push-payloads.json is out of date: UPDATE_FIXTURES=1 cargo test push_tests"
    );
}

// AK-PUSH-11
#[test]
fn a_payload_is_checked_like_the_call_it_stands_for() {
    // An update needs the revision the server sends next; the handle ignores a repeated one.
    let unnumbered = Payload::update(values! { "tone" => "red", "level" => 0.5 }).to_json();
    assert!(
        matches!(unnumbered, Err(Error::InvalidInput(_))),
        "{unnumbered:?}"
    );
    // A start is checked as the contract checks a start: its key, its layout and its values.
    let bad_key = Payload::start("la-ios-layout-push-3", "no spaces here", sketch(), first())
        .alert(Alert::new("Recording", "Tap to look"))
        .to_json();
    assert!(
        matches!(bad_key, Err(Error::InvalidInput(_))),
        "{bad_key:?}"
    );
    let unbound = Payload::start(
        "la-ios-layout-push-4",
        "pushed",
        sketch(),
        values! { "level" => "loud" },
    )
    .alert(Alert::new("Recording", "Tap to look"))
    .to_json();
    assert!(
        matches!(unbound, Err(Error::InvalidInput(_))),
        "{unbound:?}"
    );
    // Options that belong to another event are refused, not dropped.
    let misplaced = Payload::update(values! { "tone" => "red", "level" => 0.5 })
        .revision(2)
        .dismiss_at(at(1_700_003_600_000))
        .to_json();
    assert!(
        matches!(misplaced, Err(Error::InvalidInput(_))),
        "{misplaced:?}"
    );
    let misplaced = Payload::end().input_push_token().to_json();
    assert!(
        matches!(misplaced, Err(Error::InvalidInput(_))),
        "{misplaced:?}"
    );
}

// AK-PUSH-12
#[test]
fn the_headers_follow_the_bundle_id() {
    assert_eq!(
        topic("dev.example.app"),
        "dev.example.app.push-type.liveactivity"
    );
    assert_eq!(PUSH_TYPE, "liveactivity");
    assert_eq!((PRIORITY_NOW, PRIORITY_LOW), (10, 5));
}

// AK-PUSH-11
/// What APNs would refuse fails here: a payload over 4096 bytes, a start id no handle could have, a relevance that is
/// no number, and content options on an end without content.
#[test]
fn a_payload_that_apns_would_refuse_fails_here() {
    let mut big = Values::new();
    for index in 0..32 {
        big.insert(format!("v{index}"), Value::from("x".repeat(130).as_str()));
    }
    let heavy = Payload::update(big).revision(1).to_json();
    assert!(matches!(heavy, Err(Error::PayloadTooLarge(_))), "{heavy:?}");
    for id in ["", " ", &"a".repeat(257)] {
        let bad = Payload::start(id, "pushed", sketch(), first())
            .alert(Alert::new("Recording", "Tap to look"))
            .to_json();
        assert!(
            matches!(bad, Err(Error::InvalidInput(_))),
            "{id:?}: {bad:?}"
        );
    }
    let nan = Payload::update(first())
        .revision(1)
        .relevance(f64::NAN)
        .to_json();
    assert!(matches!(nan, Err(Error::InvalidInput(_))), "{nan:?}");
    for misplaced in [
        Payload::end().revision(3).to_json(),
        Payload::end().timestamp(at(1_700_000_000_000)).to_json(),
        Payload::end().stale_at(at(1_700_000_600_000)).to_json(),
    ] {
        assert!(
            matches!(misplaced, Err(Error::InvalidInput(_))),
            "{misplaced:?}"
        );
    }
    assert_eq!(MAX_PAYLOAD_BYTES, 4096);
}

// AK-PUSH-10, AK-ACCESS-1, AK-LINK-1
#[test]
fn a_start_payload_carries_links_and_accessibility_with_the_layout() {
    use crate::layout::{Accessibility, link, text};
    let layout = Layout::new(
        link(Bound::key("target"), text("Open"))
            .accessibility(Accessibility::new().label("Open the recording")),
    )
    .url("app://rec/1");
    let start = |target: &str| {
        Payload::start(
            "la-ios-layout-push-2",
            "pushed",
            layout.clone(),
            values! { "target" => target },
        )
        .alert(Alert::new("Recording", "Tap to look"))
        .to_value()
    };
    let payload = start("app://rec/1/details").unwrap();
    assert_eq!(
        payload["aps"]["attributes"]["document"]["layout"],
        json!({"lockScreen":{"type":"link","url":{"bind":"target"},"child":{"type":"text","value":"Open"},
            "accessibility":{"label":"Open the recording"}},"url":"app://rec/1"})
    );
    // A server learns here, not from a link that does nothing, that its value is no URL.
    assert_eq!(start("details").unwrap_err().code(), "INVALID_INPUT");
}
