//! The settings of the Swift layer, the lookup of a handle by id, and what the caller may choose of a content: its
//! revision and its timestamp.

use super::tests::{at, kit, sketch, started};
use super::*;
use crate::State;
use crate::{Value, fake::FakeActivity, values};
use futures_lite::future::block_on;
use serde_json::json;

fn sent(fake: &crate::fake::FakeBridge, call: Call) -> Vec<serde_json::Value> {
    fake.sent(call)
        .into_iter()
        .map(|request| request["request"]["snapshot"].clone())
        .collect()
}

fn redacted() -> Builder {
    ActivityKit::builder().receipts(Receipts::Redacted)
}

// AK-KIT-3
#[test]
fn the_first_settings_hold_and_others_conflict() {
    let (kit, fake) = kit();
    kit.settle(&redacted()).unwrap();
    let error = kit.settle(&ActivityKit::builder()).unwrap_err();
    assert_eq!(error.code(), "CONFLICT");
    kit.settle(&redacted()).unwrap();
    assert_eq!(
        fake.lock().configured,
        [
            json!({"receipts":"redacted"}),
            json!({"receipts":"full"}),
            json!({"receipts":"redacted"})
        ]
    );
    assert_eq!(fake.lock().settings, Some(json!({"receipts":"redacted"})));
    assert_eq!(ActivityKit::builder(), Builder::default());
    assert_eq!(Receipts::default(), Receipts::Full);
}

// AK-KIT-3
/// `build` hands its settings to the bridge before it returns the kit, and fails as the bridge does.
#[test]
fn build_hands_its_settings_to_the_bridge() {
    let (kit, fake) = kit();
    let built = redacted().build_on(kit.clone()).unwrap();
    assert_eq!(fake.lock().configured, [json!({"receipts":"redacted"})]);
    assert!(Arc::ptr_eq(&built.inner, &kit.inner));
    let error = ActivityKit::builder().build_on(kit).unwrap_err();
    assert_eq!(
        error,
        Error::Conflict("The Swift layer already runs with other settings.".into())
    );
    assert_eq!(fake.lock().configured.len(), 2);
}

// AK-KIT-3
#[test]
fn the_first_use_fixes_the_default_settings() {
    let (kit, _fake) = kit();
    started(&kit);
    assert_eq!(kit.settle(&redacted()).unwrap_err().code(), "CONFLICT");
    kit.settle(&ActivityKit::builder()).unwrap();
}

// AK-KIT-3
#[cfg(not(target_os = "ios"))]
#[test]
fn off_ios_build_succeeds_and_every_call_stays_unsupported() {
    let kit = redacted().build().unwrap();
    assert_eq!(
        block_on(kit.activities()).unwrap_err().code(),
        "UNSUPPORTED_PLATFORM"
    );
}

// AK-KIT-4
#[test]
fn activity_finds_a_handle_by_id() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let found = block_on(kit.activity(activity.id())).unwrap();
    assert_eq!(found, Some(activity.clone()));
    assert!(
        fake.sent(Call::List).is_empty(),
        "a live handle is found without a list"
    );
    // A handle that only a tap named does not know its revision: the list gives it.
    fake.lock().activities.push(FakeActivity {
        id: "la-tapped".into(),
        key: "tapped".into(),
        revision: 3,
        values: values! { "tone" => "red", "level" => 0.5 },
        state: State::Active,
        degraded: Vec::new(),
        timestamp: None,
        stale_at: None,
        relevance: 0.0,
    });
    let events = kit.events();
    fake.emit(json!({"type":"action","activityId":"la-tapped","actionId":"stop"}));
    let Ok(Event::Action {
        activity: tapped, ..
    }) = events.try_recv()
    else {
        panic!("a tap")
    };
    assert_eq!(tapped.revision(), None);
    let listed = block_on(kit.activity("la-tapped")).unwrap().unwrap();
    assert_eq!(
        (
            listed.revision(),
            listed == tapped,
            fake.sent(Call::List).len()
        ),
        (Some(3), true, 1)
    );
    assert_eq!(block_on(kit.activity("la-fake-404")).unwrap(), None);
    assert_eq!(fake.sent(Call::List).len(), 2);
}

// AK-HANDLE-3, AK-START-12
#[test]
fn a_start_takes_its_revision_and_timestamp() {
    let (kit, fake) = kit();
    let start = Start::new(sketch(), values! { "tone" => "green", "level" => 0.2 })
        .revision(5)
        .timestamp(at(1_790_000_000_000));
    let activity = block_on(kit.start_with(start)).unwrap();
    let [first] = sent(&fake, Call::Start).try_into().unwrap();
    assert_eq!(
        (first["revision"].clone(), first["timestamp"].clone()),
        (json!(5), json!(1_790_000_000_000u64))
    );
    assert_eq!(
        (activity.revision(), activity.timestamp()),
        (Some(5), Some(at(1_790_000_000_000)))
    );
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    assert_eq!(sent(&fake, Call::Update)[0]["revision"], json!(6));
    assert!(activity.timestamp() > Some(at(1_790_000_000_000)));
    let beyond = Start::new(sketch(), values! { "tone" => "green", "level" => 0.2 })
        .revision(9_007_199_254_740_992);
    assert_eq!(
        block_on(kit.start_with(beyond)).unwrap_err().code(),
        "INVALID_INPUT"
    );
}

// AK-UPDATE-18
#[test]
fn updates_and_ends_send_the_revision_the_caller_chose() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let red = values! { "tone" => "red", "level" => 0.8 };
    block_on(activity.update_with(Update::new(red.clone()).revision(7))).unwrap();
    // Without a revision the next one follows the highest sent.
    block_on(activity.update(values! { "tone" => "red", "level" => 0.9 })).unwrap();
    // The accepted revision again: the same content is done, other content conflicts, with no retry either way.
    let same = values! { "tone" => "red", "level" => 0.9 };
    block_on(activity.update_with(Update::new(same).revision(8))).unwrap();
    let error = block_on(activity.update_with(Update::new(red.clone()).revision(8))).unwrap_err();
    assert_eq!(error.code(), "CONFLICT");
    let error = block_on(activity.update_with(Update::new(red).revision(2))).unwrap_err();
    assert_eq!(error.code(), "STALE_REVISION");
    // A lower revision chosen and refused does not lower the count: the next automatic one is above the highest sent.
    block_on(activity.update(values! { "tone" => "red", "level" => 0.7 })).unwrap();
    let revisions: Vec<_> = sent(&fake, Call::Update)
        .iter()
        .map(|snapshot| snapshot["revision"].as_u64().unwrap())
        .collect();
    assert_eq!(revisions, [7, 8, 8, 8, 2, 9]);
    assert_eq!(activity.revision(), Some(9));
    let end = End::immediately()
        .values(values! { "tone" => "gray", "level" => 1.0 })
        .revision(12);
    block_on(activity.end(end)).unwrap();
    assert_eq!(sent(&fake, Call::End)[0]["revision"], json!(12));
    assert_eq!(
        (activity.revision(), activity.values()["tone"].clone()),
        (Some(12), Value::from("gray"))
    );
}
