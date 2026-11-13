//! What a start and an alert may ask of ActivityKit beside the content: a transient activity, a scheduled start and
//! the sound of an alert.

use super::tests::{at, kit, sketch, started};
use super::*;
use crate::{Error, State, values};
use futures_lite::future::block_on;
use serde_json::json;

fn start() -> Start {
    Start::new(sketch(), values! { "tone" => "green", "level" => 0.2 })
}

// AK-START-13
#[test]
fn a_transient_start_says_so_beside_the_request() {
    let (kit, fake) = kit();
    let activity = block_on(kit.start_with(start().transient())).unwrap();
    assert_eq!(activity.state(), State::Active);
    block_on(kit.start_with(start())).unwrap();
    let [transient, standard] = fake.sent(Call::Start).try_into().unwrap();
    assert_eq!(transient["style"], "transient");
    // The style is no part of the contract request, and a start without it names none.
    assert!(transient["request"].get("style").is_none());
    assert!(standard.get("style").is_none() && standard.get("scheduled").is_none());
}

// AK-START-13
#[test]
fn a_device_without_transient_activities_refuses_the_start() {
    let (kit, fake) = kit();
    fake.lock().fail_with = Some(
        json!({"code": "UNSUPPORTED_FEATURE", "message": "Transient activities need iOS 18.0.",
        "feature": "transient", "minimumIos": "18.0"}),
    );
    let refused = block_on(kit.start_with(start().transient())).unwrap_err();
    assert_eq!(
        refused,
        Error::UnsupportedFeature {
            feature: "transient".into(),
            minimum_ios: (18, 0)
        }
    );
}

// AK-START-14
#[test]
fn a_scheduled_start_carries_its_time_and_its_alert_and_is_pending() {
    let (kit, fake) = kit();
    let alert = Alert::new("Soon", "The recording starts").sound("chime.aiff");
    let scheduled = start().key("later").scheduled(at(1_790_000_000_000), alert);
    let activity = block_on(kit.start_with(scheduled)).unwrap();
    assert_eq!(activity.state(), State::Pending);
    let [request] = fake.sent(Call::Start).try_into().unwrap();
    assert_eq!(
        request["scheduled"],
        json!({"at": 1_790_000_000_000u64, "alert": {"title": "Soon", "body": "The recording starts", "sound": "chime.aiff"}})
    );
    assert!(request.get("style").is_none() && request.get("alert").is_none());
    // Until it began it takes no update: ActivityKit would begin it with the content of its start all the same.
    let early = block_on(activity.update(values! { "tone" => "red", "level" => 0.9 }));
    assert_eq!(early.unwrap_err().code(), "CONFLICT");
    // The system reports the start when its time comes, and the activity then takes updates.
    fake.emit(json!({"type": "state", "activityId": activity.id(), "activityKey": "later", "state": "active"}));
    assert_eq!(activity.state(), State::Active);
    fake.lock().activities[0].state = State::Active;
    block_on(activity.update(values! { "tone" => "red", "level" => 0.9 })).unwrap();
}

// AK-START-14
#[test]
fn a_scheduled_start_checks_its_time_and_its_alert_before_it_is_sent() {
    let (kit, fake) = kit();
    let alert = || Alert::new("Soon", "The recording starts");
    let before = start().scheduled(
        std::time::UNIX_EPOCH - std::time::Duration::from_secs(1),
        alert(),
    );
    let beyond = start().scheduled(at(8_640_000_000_000_001), alert());
    let unsound = start().scheduled(at(1_790_000_000_000), alert().sound("../chime.aiff"));
    for refused in [before, beyond, unsound] {
        assert_eq!(
            block_on(kit.start_with(refused)).unwrap_err(),
            Error::invalid()
        );
    }
    assert!(fake.sent(Call::Start).is_empty());
    // A start may be both: it then ends when the person leaves the app after it began.
    block_on(
        kit.start_with(
            start()
                .transient()
                .scheduled(at(1_790_000_000_000), alert()),
        ),
    )
    .unwrap();
    let [request] = fake.sent(Call::Start).try_into().unwrap();
    assert_eq!(request["style"], "transient");
    assert_eq!(
        request["scheduled"]["alert"],
        json!({"title": "Soon", "body": "The recording starts"})
    );
}

// AK-ALERT-1
#[test]
fn an_alert_names_its_sound() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let values = || values! { "tone" => "red", "level" => 0.9 };
    let loud =
        Update::new(values()).alert(Alert::new("Loud", "The level is high").sound("alarm.caf"));
    block_on(activity.update_with(loud)).unwrap();
    block_on(activity.update_with(Update::new(values()).alert(Alert::new("Loud", "Still"))))
        .unwrap();
    let [named, default] = fake.sent(Call::Update).try_into().unwrap();
    assert_eq!(
        named["alert"],
        json!({"title": "Loud", "body": "The level is high", "sound": "alarm.caf"})
    );
    // Without a sound the alert names none, and the system plays its default.
    assert_eq!(default["alert"], json!({"title": "Loud", "body": "Still"}));

    // A sound is a file name: nothing that could leave the folders the system reads sounds from.
    for name in [
        "",
        "../alarm.caf",
        "a/b.caf",
        ".hidden",
        "한.caf",
        &"a".repeat(65),
    ] {
        let update = Update::new(values()).alert(Alert::new("Loud", "x").sound(name));
        assert_eq!(
            block_on(activity.update_with(update)).unwrap_err(),
            Error::invalid(),
            "{name:?}"
        );
    }
    assert_eq!(fake.sent(Call::Update).len(), 2);
}

// AK-TOGGLE-1
#[test]
fn a_tap_on_a_toggle_says_which_state_was_asked_for() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let events = kit.events();
    let tap = |state: serde_json::Value| {
        let mut event = json!({"type": "action", "activityId": activity.id(), "actionId": "mute", "activityKey": activity.key()});
        if !state.is_null() {
            event["on"] = state;
        }
        fake.emit(event);
        match events.try_recv() {
            Ok(Event::Action { action, on, .. }) => (action, on),
            other => panic!("an action, not {other:?}"),
        }
    };
    assert_eq!(tap(json!(true)), ("mute".into(), Some(true)));
    assert_eq!(tap(json!(false)), ("mute".into(), Some(false)));
    // A button asks for no state.
    assert_eq!(tap(json!(null)), ("mute".into(), None));
}
