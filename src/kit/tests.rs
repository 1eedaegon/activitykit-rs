use super::*;
use crate::{
    Bound, Style, Value,
    events::{MAX_PENDING, TAP_WAIT},
    fake::{FakeActivity, FakeBridge},
    layout::{button, hstack, progress, symbol, text, vstack},
    values,
};
use futures_lite::future::{block_on, zip};
use serde_json::{Value as Json, json};
use std::{
    thread,
    time::{Instant, UNIX_EPOCH},
};

/// A kit on a fake bridge. A tap waits only briefly for subscribers that read later in the test.
fn kit() -> (ActivityKit, FakeBridge) {
    let fake = FakeBridge::default();
    (
        ActivityKit::with_bridge(fake.clone(), Duration::from_millis(20)),
        fake,
    )
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

fn started(kit: &ActivityKit) -> Activity {
    block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap()
}

fn at(millis: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(millis)
}

#[test]
fn start_sends_the_contract_request_and_returns_a_handle() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let [request] = fake.sent(Call::Start).try_into().unwrap();
    let key = request["request"]["activityKey"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(key.starts_with("activitykit."), "{key}");
    assert_eq!(
        request,
        json!({"request":{"activityKey":key,"schemaVersion":2,"fallback":"none",
            "layout":{"lockScreen":{"type":"vstack","children":[
                {"type":"hstack","children":[{"type":"symbol","name":"mic.fill"},
                    {"type":"text","value":"Recording","style":"status"},
                    {"type":"button","actionId":"stop","child":{"type":"text","value":"Stop"}}]},
                {"type":"progress","bind":"level"}]}},
            "styles":{"status":{"color":{"bind":"tone"}}},
            "snapshot":{"revision":0,"values":{"level":0.2,"tone":"green"}}}})
    );
    assert_eq!((activity.id(), activity.key()), ("la-fake-1", key.as_str()));
    assert_eq!(
        (activity.state(), activity.revision()),
        (State::Active, Some(0))
    );
    assert_eq!(
        activity.values(),
        values! { "tone" => "green", "level" => 0.2 }
    );
    assert!(activity.degraded_features().is_empty());
    // Every start without a key is a new activity.
    let second = started(&kit);
    assert_ne!(second, activity);
    assert_ne!(
        fake.sent(Call::Start)[1]["request"]["activityKey"],
        json!(key)
    );
}

#[test]
fn start_options_reach_the_request() {
    let (kit, fake) = kit();
    let start = Start::new(
        sketch(),
        [("tone", Value::from("red")), ("level", Value::from(1))],
    )
    .key("recording")
    .stale_at(at(1_790_000_000_000))
    .relevance(50.0);
    let activity = block_on(kit.start_with(start)).unwrap();
    assert_eq!(activity.key(), "recording");
    let [request] = fake.sent(Call::Start).try_into().unwrap();
    assert_eq!(request["request"]["activityKey"], "recording");
    assert_eq!(
        request["request"]["snapshot"]["staleAt"],
        1_790_000_000_000u64
    );
    assert_eq!(request["relevance"], 50.0);
    assert!(request.get("alert").is_none());
}

#[test]
fn a_request_that_breaks_the_contract_never_reaches_the_bridge() {
    let (kit, fake) = kit();
    let unstyled = Layout::new(text("a").style("missing"));
    assert_eq!(
        block_on(kit.start(unstyled, values! {})).unwrap_err(),
        Error::invalid()
    );
    let bad_key = Start::new(Layout::new(text("a")), values! {}).key("../secret");
    assert_eq!(
        block_on(kit.start_with(bad_key)).unwrap_err().code(),
        "INVALID_INPUT"
    );
    let before_epoch = Start::new(Layout::new(text("a")), values! {})
        .stale_at(UNIX_EPOCH - Duration::from_secs(1));
    assert_eq!(
        block_on(kit.start_with(before_epoch)).unwrap_err().code(),
        "INVALID_INPUT"
    );
    let endless = Start::new(Layout::new(text("a")), values! {}).relevance(f64::NAN);
    assert_eq!(
        block_on(kit.start_with(endless)).unwrap_err().code(),
        "INVALID_INPUT"
    );
    let heavy: Values = (0..4)
        .map(|key| (format!("k{key}"), "x".repeat(1000)))
        .collect();
    assert_eq!(
        block_on(kit.start(Layout::new(text("a")), heavy))
            .unwrap_err()
            .code(),
        "PAYLOAD_TOO_LARGE"
    );
    assert!(fake.lock().requests.is_empty());

    let activity = started(&kit);
    let wrong = Update::new(values! { "tone" => "red", "level" => 0.8 }).relevance(f64::INFINITY);
    assert_eq!(
        block_on(activity.update_with(wrong)).unwrap_err().code(),
        "INVALID_INPUT"
    );
    let late = Update::new(values! { "tone" => "red", "level" => 0.8 })
        .stale_at(UNIX_EPOCH - Duration::from_secs(1));
    assert_eq!(
        block_on(activity.update_with(late)).unwrap_err().code(),
        "INVALID_INPUT"
    );
    let too_many: Values = (0..33).map(|key| (format!("k{key}"), key)).collect();
    assert_eq!(
        block_on(activity.update(too_many)).unwrap_err().code(),
        "INVALID_INPUT"
    );
    assert!(fake.sent(Call::Update).is_empty());
    // A rejected update reserves no revision.
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    assert_eq!(
        fake.sent(Call::Update)[0]["request"]["snapshot"]["revision"],
        1
    );
}

#[test]
fn updates_carry_the_next_revision_and_their_options() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    let update = Update::new(values! { "tone" => "red", "level" => 1.0 })
        .alert(Alert::new("Loud", "The level is high"))
        .relevance(80.0)
        .stale_at(at(1_790_000_000_000));
    block_on(activity.update_with(update)).unwrap();
    let [first, second] = fake.sent(Call::Update).try_into().unwrap();
    assert_eq!(
        first,
        json!({"request":{"id":"la-fake-1","snapshot":{"revision":1,"values":{"level":0.8,"tone":"red"}}}})
    );
    assert_eq!(
        second,
        json!({"request":{"id":"la-fake-1","snapshot":{"revision":2,"values":{"level":1.0,"tone":"red"},
            "staleAt":1_790_000_000_000u64}},"relevance":80.0,"alert":{"title":"Loud","body":"The level is high"}})
    );
    assert_eq!(activity.revision(), Some(2));
    assert_eq!(activity.values()["level"], Value::Number(1.0));
}

#[test]
fn clones_share_the_revision_and_concurrent_updates_never_reuse_one() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().delay = Some(Duration::from_millis(20));
    let other = activity.clone();
    let (a, b) = block_on(zip(
        activity.update(values! { "tone" => "red", "level" => 0.5 }),
        other.update(values! { "tone" => "red", "level" => 0.6 }),
    ));
    a.unwrap();
    b.unwrap();
    let revisions: Vec<_> = fake
        .sent(Call::Update)
        .iter()
        .map(|request| request["request"]["snapshot"]["revision"].clone())
        .collect();
    assert_eq!(revisions, [json!(1), json!(2)]);
    assert_eq!((activity.revision(), other.revision()), (Some(2), Some(2)));
    assert_eq!(other.values()["level"], Value::Number(0.6));
    // Updates from other threads, through handles that the list gives, continue the same count.
    let listed = block_on(kit.activities()).unwrap();
    let threads: Vec<_> = (0..4)
        .map(|index| {
            let handle = listed[0].clone();
            thread::spawn(move || {
                block_on(handle.update(values! { "tone" => "red", "level" => index })).unwrap()
            })
        })
        .collect();
    threads
        .into_iter()
        .for_each(|thread| thread.join().unwrap());
    let mut revisions: Vec<_> = fake
        .sent(Call::Update)
        .iter()
        .skip(2)
        .map(|request| request["request"]["snapshot"]["revision"].as_u64().unwrap())
        .collect();
    revisions.sort_unstable();
    assert_eq!(revisions, [3, 4, 5, 6]);
    assert_eq!(activity.revision(), Some(6));
}

#[test]
fn a_handle_after_a_relaunch_continues_from_the_listed_revision() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    drop((activity, kit));
    // The process starts again; ActivityKit and the receipts still know the activity.
    let relaunched = ActivityKit::with_bridge(fake.clone(), TAP_WAIT);
    let [activity] = block_on(relaunched.activities())
        .unwrap()
        .try_into()
        .unwrap();
    assert_eq!(
        (activity.revision(), activity.state()),
        (Some(1), State::Active)
    );
    assert_eq!(activity.values()["tone"], Value::from("red"));
    block_on(activity.update(values! { "tone" => "green", "level" => 0.1 })).unwrap();
    assert_eq!(
        fake.sent(Call::Update).last().unwrap()["request"]["snapshot"]["revision"],
        2
    );
    // The list hands out the same handle while one is alive.
    assert_eq!(
        block_on(relaunched.activities()).unwrap()[0].revision(),
        Some(2)
    );
}

#[test]
fn a_handle_that_only_an_event_named_learns_its_revision_from_the_list() {
    let (kit, fake) = kit();
    fake.lock().activities.push(FakeActivity {
        id: "la-ios-layout-1".into(),
        key: "recording".into(),
        revision: 7,
        values: values! { "tone" => "red" },
        state: State::Active,
    });
    let events = kit.events();
    fake.emit(json!({"type":"action","activityId":"la-ios-layout-1","actionId":"stop","activityKey":"recording"}));
    let Ok(Event::Action { activity, action }) = events.try_recv() else {
        panic!("an action event")
    };
    assert_eq!(
        (action.as_str(), activity.key(), activity.revision()),
        ("stop", "recording", None)
    );
    block_on(activity.update(values! { "tone" => "green" })).unwrap();
    assert_eq!(fake.sent(Call::List).len(), 1);
    assert_eq!(
        fake.sent(Call::Update)[0]["request"]["snapshot"]["revision"],
        8
    );
    // An activity that the list does not know is gone.
    fake.emit(json!({"type":"action","activityId":"la-ios-layout-gone","actionId":"stop"}));
    let Ok(Event::Action { activity, .. }) = events.try_recv() else {
        panic!("an action event")
    };
    assert_eq!(activity.key(), "");
    assert_eq!(
        block_on(activity.update(values! {})).unwrap_err().code(),
        "NOT_FOUND"
    );
}

#[test]
fn a_stale_revision_refreshes_from_the_list_and_retries_once() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    // Another handle of an earlier process advanced the activity without this one knowing.
    fake.lock().activities[0].revision = 5;
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    let revisions: Vec<_> = fake
        .sent(Call::Update)
        .iter()
        .map(|request| request["request"]["snapshot"]["revision"].clone())
        .collect();
    assert_eq!(revisions, [json!(1), json!(6)]);
    assert_eq!(activity.revision(), Some(6));
    // Other errors are not retried.
    fake.lock().fail = Some((
        "CONFLICT",
        "This revision already contains different state.",
    ));
    let error = block_on(activity.update(values! { "tone" => "red", "level" => 0.9 })).unwrap_err();
    assert_eq!(
        error,
        Error::Conflict("This revision already contains different state.".into())
    );
    assert_eq!(fake.sent(Call::Update).len(), 3);
}

#[test]
fn end_sends_its_policy_and_the_handle_reports_the_state() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    block_on(activity.end(End::immediately())).unwrap();
    block_on(activity.end(End::default())).unwrap();
    block_on(activity.end(End::after(at(1_790_000_000_000)))).unwrap();
    let policies: Vec<_> = fake
        .sent(Call::End)
        .iter()
        .map(|request| request["request"]["policy"].clone())
        .collect();
    assert_eq!(
        policies,
        [
            json!({"kind":"immediate"}),
            json!({"kind":"default"}),
            json!({"kind":"after","at":1_790_000_000_000u64})
        ]
    );
    assert_eq!(
        fake.sent(Call::End)[0],
        json!({"request":{"id":"la-fake-1","policy":{"kind":"immediate"}}})
    );
    assert_eq!(activity.state(), State::Ended);
    assert_eq!(
        block_on(activity.update(values! { "tone" => "red", "level" => 0.1 }))
            .unwrap_err()
            .code(),
        "NOT_FOUND"
    );
    assert_eq!(
        block_on(activity.end(End::after(UNIX_EPOCH - Duration::from_secs(1))))
            .unwrap_err()
            .code(),
        "INVALID_INPUT"
    );
}

#[test]
fn swift_errors_keep_their_codes_and_messages() {
    let (kit, fake) = kit();
    fake.lock().fail = Some((
        "PERMISSION_DENIED",
        "Live Activities are disabled in system settings.",
    ));
    let error =
        block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap_err();
    assert_eq!(
        error,
        Error::PermissionDenied("Live Activities are disabled in system settings.".into())
    );
    fake.lock().fail = Some((
        "UNSUPPORTED_PLATFORM",
        "Live Activities require iPhone with iOS 16.1.",
    ));
    assert_eq!(block_on(kit.activities()).unwrap_err(), Error::Unsupported);
    fake.lock().fail = Some((
        "CONFIGURATION_REQUIRED",
        "Embed a widget extension built from the layout template.",
    ));
    assert_eq!(
        block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 }))
            .unwrap_err()
            .code(),
        "CONFIGURATION_REQUIRED"
    );
}

#[test]
fn every_subscriber_gets_every_event_with_the_shared_handle() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let (first, second) = (kit.events(), kit.clone().events());
    fake.emit(
        json!({"type":"action","activityId":"la-fake-1","actionId":"stop","activityKey":"ignored"}),
    );
    fake.emit(
        json!({"type":"state","activityId":"la-fake-1","activityKey":"x","state":"dismissed"}),
    );
    fake.emit(json!({"type":"authorization","enabled":false}));
    for events in [first, second] {
        let Ok(Event::Action {
            activity: tapped,
            action,
        }) = events.try_recv()
        else {
            panic!("an action")
        };
        assert_eq!(
            (tapped.clone(), action.as_str(), tapped.key()),
            (activity.clone(), "stop", activity.key())
        );
        let Ok(Event::State {
            activity: changed,
            state,
        }) = events.try_recv()
        else {
            panic!("a state")
        };
        assert_eq!((changed, state), (activity.clone(), State::Dismissed));
        assert!(matches!(
            events.try_recv(),
            Ok(Event::Authorization { enabled: false })
        ));
        assert!(events.try_recv().is_err());
    }
    // The tapped handle is the started one: it knows the revision, and the state the event reported.
    assert_eq!(activity.state(), State::Dismissed);
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    assert_eq!(
        fake.sent(Call::Update)[0]["request"]["snapshot"]["revision"],
        1
    );
    assert!(fake.sent(Call::List).is_empty());
}

#[test]
fn events_before_the_first_subscriber_wait_for_it() {
    let (kit, fake) = kit();
    for index in 0..MAX_PENDING + 2 {
        fake.emit(json!({"type":"action","activityId":"la-1","actionId":format!("tap{index}")}));
    }
    fake.emit(json!({"type":"unknown"}));
    fake.emit(json!({"type":"action"}));
    let events = kit.events();
    let actions: Vec<_> = std::iter::from_fn(|| match events.try_recv() {
        Ok(Event::Action { action, .. }) => Some(action),
        _ => None,
    })
    .collect();
    assert_eq!(actions.len(), MAX_PENDING);
    assert_eq!(
        (actions[0].as_str(), actions[MAX_PENDING - 1].as_str()),
        ("tap2", "tap17")
    );
    // A receiver that is dropped gets nothing more, and a later one starts with what came meanwhile.
    drop(events);
    fake.emit(json!({"type":"authorization","enabled":true}));
    assert!(matches!(
        kit.events().try_recv(),
        Ok(Event::Authorization { enabled: true })
    ));
}

#[test]
fn a_tap_returns_once_every_subscriber_has_taken_it() {
    let fake = FakeBridge::default();
    let kit = ActivityKit::with_bridge(fake.clone(), Duration::from_secs(10));
    let events = kit.events();
    let taker = thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        events.recv_blocking().unwrap()
    });
    let started = Instant::now();
    fake.emit(json!({"type":"action","activityId":"la-1","actionId":"stop"}));
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(100) && waited < Duration::from_secs(5),
        "{waited:?}"
    );
    assert!(matches!(taker.join().unwrap(), Event::Action { .. }));
    // States and authorization changes do not wait.
    let _idle = kit.events();
    let started = Instant::now();
    fake.emit(json!({"type":"authorization","enabled":true}));
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[test]
fn the_wait_for_a_tap_is_bounded() {
    let fake = FakeBridge::default();
    let kit = ActivityKit::with_bridge(fake.clone(), Duration::from_millis(150));
    let idle = kit.events();
    let started = Instant::now();
    fake.emit(json!({"type":"action","activityId":"la-1","actionId":"stop"}));
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(150) && waited < Duration::from_secs(2),
        "{waited:?}"
    );
    assert_eq!(idle.len(), 1);
    // A receiver dropped meanwhile does not hold the tap.
    drop(idle);
    let started = Instant::now();
    fake.emit(json!({"type":"action","activityId":"la-1","actionId":"stop"}));
    assert!(started.elapsed() < Duration::from_millis(100));
}

#[test]
fn authorization_reads_the_bridge() {
    let (kit, fake) = kit();
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: true,
            enabled: true,
            buttons: true
        }
    );
    fake.lock().authorization =
        Some(json!({"supported":true,"enabled":false,"buttons":false,"later":1}));
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: true,
            enabled: false,
            buttons: false
        }
    );
    fake.lock().authorization = Some(json!("broken"));
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: false,
            enabled: false,
            buttons: false
        }
    );
}

#[test]
fn images_go_to_the_folder_the_bridge_names() {
    let (kit, fake) = kit();
    let png = crate::image::tests::png(8, 8, 4);
    assert_eq!(
        kit.write_image("badge.png", &png).unwrap_err().code(),
        "CONFIGURATION_REQUIRED"
    );
    let folder = std::env::temp_dir().join(format!("activitykit-images-{}", std::process::id()));
    std::fs::create_dir_all(&folder).unwrap();
    fake.lock().folder = Some(folder.clone());
    kit.write_image("badge.png", &png).unwrap();
    assert_eq!(std::fs::read(folder.join("badge.png")).unwrap(), png);
    // The folder is asked for once.
    fake.lock().folder = None;
    kit.write_image("badge.png", &png).unwrap();
    assert_eq!(
        kit.write_image("../badge.png", &png).unwrap_err().code(),
        "INVALID_INPUT"
    );
    std::fs::remove_dir_all(&folder).unwrap();
}

#[test]
fn debug_output_names_the_activity_without_its_values() {
    let (kit, _fake) = kit();
    let activity = started(&kit);
    let debug = format!("{activity:?} {kit:?}");
    assert!(
        debug.contains("la-fake-1") && debug.contains("Active") && !debug.contains("green"),
        "{debug}"
    );
}

#[cfg(not(target_os = "ios"))]
#[test]
fn off_ios_every_call_is_unsupported_after_the_contract_check() {
    let kit = ActivityKit::default();
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: false,
            enabled: false,
            buttons: false
        }
    );
    assert_eq!(
        block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap_err(),
        Error::Unsupported
    );
    assert_eq!(
        block_on(kit.start(Layout::new(text("a").style("missing")), values! {}))
            .unwrap_err()
            .code(),
        "INVALID_INPUT"
    );
    assert_eq!(block_on(kit.activities()).unwrap_err(), Error::Unsupported);
    let png = crate::image::tests::png(8, 8, 4);
    assert_eq!(
        kit.write_image("badge.png", &png).unwrap_err(),
        Error::Unsupported
    );
    assert_eq!(
        kit.write_image("badge.png", b"GIF89a").unwrap_err().code(),
        "INVALID_INPUT"
    );
    assert!(matches!(
        kit.events().try_recv(),
        Err(async_channel::TryRecvError::Empty)
    ));
}

#[test]
fn bound_text_and_wire_values_round_trip() {
    let json: Json = serde_json::to_value(text(Bound::key("status"))).unwrap();
    assert_eq!(json, json!({"type":"text","bind":"status"}));
}

/// Any executor can run the futures, a multi-threaded one too, and every type crosses threads.
#[test]
fn futures_are_send_and_types_are_send_and_sync() {
    fn send<T: Send>(_: &T) {}
    fn shared<T: Send + Sync>() {}
    shared::<ActivityKit>();
    shared::<Activity>();
    shared::<Event>();
    shared::<Error>();
    let (kit, _fake) = kit();
    let activity = started(&kit);
    send(&kit.start(sketch(), values! {}));
    send(&kit.activities());
    send(&activity.update(values! {}));
    send(&activity.update_with(Update::new(values! {})));
    send(&activity.end(End::immediately()));
}
