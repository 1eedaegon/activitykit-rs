//! Pushes as the kit sees them: the token an activity asks for, the tokens and the content the Swift layer reports,
//! the push-to-start setting, and frequent pushes in the authorization.

use super::tests::{kit, sketch, started};
use super::*;
use crate::{
    Error, Event, State, Value,
    bridge::Call,
    fake::FakeBridge,
    push::{ChannelId, Push, PushToken},
    values,
};
use futures_lite::future::block_on;
use serde_json::json;
use std::time::{Duration, UNIX_EPOCH};

fn at(millis: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(millis)
}

// AK-PUSH-1, AK-PUSH-3
/// The start request names what the activity asks for: a token, a channel, or nothing.
#[test]
fn a_start_asks_for_a_push_token_or_a_channel() {
    let (kit, fake) = kit();
    let content = values! { "tone" => "green", "level" => 0.2 };
    block_on(kit.start_with(Start::new(sketch(), content.clone()).push(Push::Token))).unwrap();
    let channel = ChannelId::new("dHN0LXNyY2gtY2hubA==").unwrap();
    block_on(kit.start_with(Start::new(sketch(), content.clone()).push(Push::Channel(channel))))
        .unwrap();
    block_on(kit.start(sketch(), content)).unwrap();
    let sent = fake.sent(Call::Start);
    assert_eq!(sent[0]["request"]["push"], json!("token"));
    assert_eq!(
        sent[1]["request"]["push"],
        json!({"channel": "dHN0LXNyY2gtY2hubA=="})
    );
    assert_eq!(sent[2]["request"].get("push"), None, "no push unless asked");
}

// AK-PUSH-3
/// A channel id is the base64 text APNs gave the server.
#[test]
fn a_channel_id_is_base64_text() {
    let channel = ChannelId::new("dHN0LXNyY2gtY2hubA==").unwrap();
    assert_eq!(channel.as_str(), "dHN0LXNyY2gtY2hubA==");
    assert!(
        ChannelId::new("abcd").is_ok()
            && ChannelId::new("ab==").is_ok()
            && ChannelId::new("a-_/".repeat(256)).is_ok()
    );
    for bad in [
        "",
        "not base64!",
        "dHN0 LXNy",
        "====",
        "a\n",
        "abc",
        "ab=",
        "abcde",
        &"a".repeat(1028),
    ] {
        assert!(
            matches!(ChannelId::new(bad), Err(Error::InvalidInput(_))),
            "{bad:?} is no channel id"
        );
    }
}

// AK-PUSH-2
/// A token arrives with the handle the app holds, and displays as lowercase hex whatever case the bridge wrote.
#[test]
fn a_push_token_arrives_as_an_event_in_lowercase_hex() {
    let (kit, fake) = kit();
    let events = kit.events();
    let activity = started(&kit);
    fake.emit(json!({"type":"pushToken","activityId":activity.id(),"activityKey":activity.key(),"token":"0A1bFF"}));
    let Ok(Event::PushToken {
        activity: tokened,
        token,
        ..
    }) = events.try_recv()
    else {
        panic!("a push token event")
    };
    assert_eq!(tokened, activity);
    assert_eq!(token.to_string(), "0a1bff");
    assert_eq!(token.as_bytes(), [0x0a, 0x1b, 0xff]);
    assert_eq!(format!("{token:?}"), "PushToken(0a1bff)");
    assert_eq!(token, PushToken::from(vec![0x0a, 0x1b, 0xff]));
}

// AK-PUSH-2
/// A token that is no hex, or empty, is no token: the event is dropped.
#[test]
fn an_unreadable_token_is_dropped() {
    let (kit, fake) = kit();
    let events = kit.events();
    let activity = started(&kit);
    for bad in ["zz", "", "abc", "0a 1b"] {
        fake.emit(json!({"type":"pushToken","activityId":activity.id(),"activityKey":activity.key(),"token":bad}));
        fake.emit(json!({"type":"pushToStartToken","token":bad}));
    }
    assert!(
        events.try_recv().is_err(),
        "no event for an unreadable token"
    );
}

// AK-PUSH-4
/// The setting goes to the Swift layer with the receipts, holds like them, and the token it reports is an event.
#[test]
fn the_push_to_start_token_is_watched_only_when_asked() {
    let fake = FakeBridge::default();
    let plain = ActivityKit::with_bridge(fake.clone(), Duration::from_millis(20));
    assert_eq!(fake.lock().configured, Vec::<serde_json::Value>::new());
    let kit = ActivityKit::builder()
        .push_to_start(true)
        .build_on(plain)
        .unwrap();
    assert_eq!(
        fake.lock().configured,
        [json!({"receipts":"full","pushToStart":true})]
    );
    let events = kit.events();
    fake.emit(json!({"type":"pushToStartToken","token":"abcd"}));
    let Ok(Event::PushToStartToken { token, .. }) = events.try_recv() else {
        panic!("a push-to-start token event")
    };
    assert_eq!(token.to_string(), "abcd");
    // The first settings hold: a build without the setting is other settings.
    let again = ActivityKit::builder().build_on(kit.clone());
    assert!(matches!(again, Err(Error::Conflict(_))), "{again:?}");
    // A kit built without the setting sends none: the Swift layer watches nothing by default.
    let other = FakeBridge::default();
    ActivityKit::builder()
        .build_on(ActivityKit::with_bridge(
            other.clone(),
            Duration::from_millis(20),
        ))
        .unwrap();
    assert_eq!(other.lock().configured, [json!({"receipts":"full"})]);
}

// AK-PUSH-5
/// An activity a push started is news like any other, with the key the payload gave it, and the list has it.
#[test]
fn a_pushed_activity_arrives_started_with_its_key() {
    let (kit, fake) = kit();
    let events = kit.events();
    fake.lock().activities.push(crate::fake::FakeActivity {
        id: "la-ios-layout-pushed".into(),
        key: "pushed".into(),
        revision: 0,
        values: values! { "tone" => "red", "level" => 0.5 },
        state: State::Active,
        degraded: Vec::new(),
        timestamp: None,
        stale_at: None,
        relevance: 0.0,
    });
    fake.emit(json!({"type":"started","activityId":"la-ios-layout-pushed","activityKey":"pushed"}));
    let Ok(Event::Started { activity, .. }) = events.try_recv() else {
        panic!("a started event")
    };
    assert_eq!(
        (activity.id(), activity.key()),
        ("la-ios-layout-pushed", "pushed")
    );
    let listed = block_on(kit.activities()).unwrap();
    assert_eq!(listed, std::slice::from_ref(&activity));
    assert_eq!(
        activity.revision(),
        Some(0),
        "the list told the handle its content"
    );
    assert_eq!(activity.values()["tone"], Value::Text("red".into()));
}

// AK-PUSH-6
/// Content above the accepted revision reaches the handle once; the rest changes nothing.
#[test]
fn content_a_push_delivers_reaches_the_handle_once() {
    let (kit, fake) = kit();
    let events = kit.events();
    let activity = started(&kit);
    block_on(activity.update(values! { "tone" => "green", "level" => 0.3 })).unwrap();
    assert_eq!(activity.revision(), Some(1));
    let content = |revision: u64, tone: &str| {
        json!({"type":"content","activityId":activity.id(),"activityKey":activity.key(),
            "snapshot":{"revision":revision,"values":{"tone":tone,"level":0.9},"timestamp":1_700_000_000_000u64,"staleAt":1_700_000_600_000u64},
            "relevance":80.0})
    };
    // ActivityKit reports the app's own update back: nothing new.
    fake.emit(content(1, "green"));
    assert!(
        events.try_recv().is_err(),
        "the app's own content is not news"
    );
    assert_eq!(activity.values()["level"], Value::Number(0.3));
    // A push above the accepted revision: the handle takes it, and says so once.
    fake.emit(content(3, "red"));
    let Ok(Event::Updated {
        activity: updated, ..
    }) = events.try_recv()
    else {
        panic!("an updated event")
    };
    assert_eq!(updated, activity);
    assert!(events.try_recv().is_err(), "one event per content");
    assert_eq!(activity.revision(), Some(3));
    assert_eq!(
        activity.values(),
        values! { "tone" => "red", "level" => 0.9 }
    );
    assert_eq!(activity.timestamp(), Some(at(1_700_000_000_000)));
    assert_eq!(activity.stale_at(), Some(at(1_700_000_600_000)));
    assert_eq!(activity.relevance(), 80.0);
    // Content at or below that revision changes nothing.
    fake.emit(content(3, "blue"));
    fake.emit(content(2, "blue"));
    assert!(events.try_recv().is_err());
    assert_eq!(activity.values()["tone"], Value::Text("red".into()));
    // The next write of the app goes out above the pushed revision.
    block_on(activity.update(values! { "tone" => "green", "level" => 0.4 })).unwrap();
    let sent = fake.sent(Call::Update);
    assert_eq!(sent.last().unwrap()["request"]["snapshot"]["revision"], 4);
    assert_eq!(activity.revision(), Some(4));
}

// AK-PUSH-8
/// The authorization carries whether frequent pushes are allowed; a reply without it says no.
#[test]
fn frequent_pushes_are_part_of_the_authorization() {
    let (kit, fake) = kit();
    assert!(
        !kit.authorization().frequent_pushes,
        "the fake's reply has no member for it"
    );
    fake.lock().authorization =
        Some(json!({"supported":true,"enabled":true,"buttons":true,"frequentPushes":true}));
    let authorization = kit.authorization();
    assert!(authorization.frequent_pushes);
    let Authorization {
        supported, enabled, ..
    } = authorization;
    assert!(supported && enabled);
    let events = kit.events();
    fake.emit(json!({"type":"authorization","authorization":{"supported":true,"enabled":true,"buttons":true,"frequentPushes":false}}));
    let Ok(Event::Authorization(changed)) = events.try_recv() else {
        panic!("an authorization event")
    };
    assert!(!changed.frequent_pushes);
}

// AK-PUSH-3
/// The start request takes a channel object with nothing but the channel, as the Swift layer reads it.
#[test]
fn a_channel_object_has_no_other_member() {
    let (regions, styles) = sketch().into_wire();
    let start = |push: serde_json::Value| {
        let mut request = serde_json::to_value(crate::contract::LayoutStartInput {
            activity_key: "a".into(),
            schema_version: 2,
            fallback: crate::contract::Fallback::None,
            layout: regions.clone(),
            styles: styles.clone(),
            snapshot: crate::contract::LayoutSnapshot {
                revision: 0,
                values: values! { "tone" => "green", "level" => 0.2 },
                stale_at: None,
                timestamp: None,
            },
            android: None,
            push: None,
        })
        .unwrap();
        request["push"] = push;
        crate::contract::validate_request("start_layout", request)
    };
    assert!(start(json!("token")).is_ok());
    assert!(start(json!({"channel": "abcd"})).is_ok());
    for bad in [
        json!({"channel": "abcd", "more": 1}),
        json!({"channel": 1}),
        json!("later"),
        json!(1),
        json!({"channel": "a"}),
    ] {
        assert!(
            matches!(start(bad.clone()), Err(Error::InvalidInput(_))),
            "{bad}"
        );
    }
}

// AK-PUSH-6
/// The kit keeps what it learned of an activity while the process runs, handle or no handle: the app's own update,
/// reported back after the handle was dropped, is not news; a push above it is.
#[test]
fn the_kit_remembers_a_dropped_handles_revisions() {
    let (kit, fake) = kit();
    let events = kit.events();
    let activity = started(&kit);
    block_on(activity.update(values! { "tone" => "green", "level" => 0.3 })).unwrap();
    let (id, key) = (activity.id().to_owned(), activity.key().to_owned());
    drop(activity);
    let content = |revision: u64, tone: &str| {
        json!({"type":"content","activityId":id,"activityKey":key,
            "snapshot":{"revision":revision,"values":{"tone":tone,"level":0.9}}})
    };
    fake.emit(content(1, "green"));
    assert!(
        events.try_recv().is_err(),
        "the app's own content, reported back, is not news without a handle either"
    );
    fake.emit(content(2, "red"));
    let Ok(Event::Updated {
        activity: pushed, ..
    }) = events.try_recv()
    else {
        panic!("an updated event")
    };
    assert_eq!((pushed.id(), pushed.revision()), (id.as_str(), Some(2)));
    // The handle the kit gives for the id is the one that knows.
    let found = block_on(kit.activity(&id))
        .unwrap()
        .expect("the kit knows the activity");
    assert_eq!(found, pushed);
    // Once the activity is dismissed and nobody holds it, the next activity the kit meets lets it go: content
    // at the old revision is news again, since nothing remembers the revisions.
    fake.emit(json!({"type":"state","activityId":id,"activityKey":key,"state":"dismissed"}));
    assert!(matches!(events.try_recv(), Ok(Event::State { .. })));
    drop((pushed, found));
    fake.emit(json!({"type":"started","activityId":"la-ios-layout-other","activityKey":"other"}));
    assert!(matches!(events.try_recv(), Ok(Event::Started { .. })));
    fake.emit(content(1, "green"));
    let Ok(Event::Updated {
        activity: fresh, ..
    }) = events.try_recv()
    else {
        panic!("the forgotten activity's content is news again")
    };
    assert_eq!((fresh.id(), fresh.revision()), (id.as_str(), Some(1)));
}
