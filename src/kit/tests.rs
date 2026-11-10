use super::*;
use crate::State;
use crate::{
    Bound, LimitScope, Style, Value,
    events::{MAX_PENDING, TAP_WAIT},
    fake::{FakeActivity, FakeBridge},
    layout::{button, hstack, progress, symbol, text, vstack},
    values,
};
use futures_lite::future::{block_on, zip};
use serde_json::{Value as Json, json};
use std::sync::atomic::AtomicBool;
use std::{
    thread,
    time::{Instant, UNIX_EPOCH},
};

/// A fake bridge that keeps its replies while `hold(true)`, as a Swift layer that lost its callback would.
#[derive(Clone, Default)]
pub(super) struct HoldingBridge {
    fake: FakeBridge,
    holding: Arc<AtomicBool>,
    held: Arc<Mutex<Vec<bridge::Reply>>>,
}

impl HoldingBridge {
    pub(super) fn hold(&self, holding: bool) {
        self.holding.store(holding, Ordering::SeqCst);
    }

    /// The replies kept so far, oldest first.
    pub(super) fn held(&self) -> Vec<bridge::Reply> {
        std::mem::take(&mut *self.held.lock().unwrap())
    }
}

impl Bridge for HoldingBridge {
    fn call(&self, call: Call, request: Vec<u8>, reply: bridge::Reply) {
        if self.holding.load(Ordering::SeqCst) {
            self.held.lock().unwrap().push(reply);
        } else {
            self.fake.call(call, request, reply);
        }
    }
    fn authorization(&self) -> Vec<u8> {
        self.fake.authorization()
    }
    fn image_folder(&self) -> Vec<u8> {
        self.fake.image_folder()
    }
    fn configure(&self, request: Vec<u8>) -> Vec<u8> {
        self.fake.configure(request)
    }
    fn listen(&self, events: bridge::Events) {
        self.fake.listen(events);
    }
}

/// A kit on a fake bridge. A tap waits only briefly for subscribers that read later in the test.
pub(super) fn kit() -> (ActivityKit, FakeBridge) {
    let fake = FakeBridge::default();
    (
        ActivityKit::with_bridge(fake.clone(), Duration::from_millis(20)),
        fake,
    )
}

pub(super) fn sketch() -> Layout {
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

pub(super) fn started(kit: &ActivityKit) -> Activity {
    block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap()
}

pub(super) fn at(millis: u64) -> SystemTime {
    UNIX_EPOCH + Duration::from_millis(millis)
}

/// A request without its snapshot's timestamp, the time it was made, which every snapshot carries.
pub(super) fn untimed(mut request: Json) -> Json {
    let snapshot = request["request"]["snapshot"]
        .as_object_mut()
        .expect("a snapshot");
    assert!(
        snapshot.remove("timestamp").is_some_and(|at| at.is_u64()),
        "a timestamp"
    );
    request
}

// AK-HANDLE-2, AK-HANDLE-3, AK-START-1, AK-START-2
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
        untimed(request),
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

// AK-START-3, AK-START-4
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

// AK-START-4, AK-START-5, AK-START-6, AK-UPDATE-2, AK-UPDATE-6, AK-UPDATE-9
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

// AK-HANDLE-3, AK-UPDATE-1, AK-UPDATE-2
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
        untimed(first),
        json!({"request":{"id":"la-fake-1","snapshot":{"revision":1,"values":{"level":0.8,"tone":"red"}}}})
    );
    assert_eq!(
        untimed(second),
        json!({"request":{"id":"la-fake-1","snapshot":{"revision":2,"values":{"level":1.0,"tone":"red"},
            "staleAt":1_790_000_000_000u64}},"relevance":80.0,"alert":{"title":"Loud","body":"The level is high"}})
    );
    assert_eq!(activity.revision(), Some(2));
    assert_eq!(activity.values()["level"], Value::Number(1.0));
}

// AK-THREAD-1, AK-UPDATE-3
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

// AK-LIST-1, AK-LIST-2, AK-STATE-3
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

// AK-EVENT-12, AK-UPDATE-7, AK-UPDATE-8
#[test]
fn a_handle_that_only_an_event_named_learns_its_revision_from_the_list() {
    let (kit, fake) = kit();
    fake.lock().activities.push(FakeActivity {
        id: "la-ios-layout-1".into(),
        key: "recording".into(),
        revision: 7,
        values: values! { "tone" => "red" },
        state: State::Active,
        degraded: Vec::new(),
        timestamp: None,
        stale_at: None,
        relevance: 0.0,
    });
    let events = kit.events();
    fake.emit(json!({"type":"action","activityId":"la-ios-layout-1","actionId":"stop","activityKey":"recording"}));
    let Ok(Event::Action {
        activity, action, ..
    }) = events.try_recv()
    else {
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

// AK-UPDATE-4
#[test]
fn a_stale_revision_refreshes_from_the_list_and_retries_once_when_newer() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    // Another handle of an earlier process advanced the activity, with content from before this update.
    fake.lock().activities[0].revision = 5;
    fake.lock().activities[0].timestamp = Some(1_000);
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    let revisions: Vec<_> = fake
        .sent(Call::Update)
        .iter()
        .map(|request| request["request"]["snapshot"]["revision"].clone())
        .collect();
    assert_eq!(revisions, [json!(1), json!(6)]);
    assert_eq!(activity.revision(), Some(6));
    // Content newer than this update wins: no retry.
    fake.lock().activities[0].revision = 9;
    fake.lock().activities[0].timestamp = Some(u64::MAX / 2);
    let error =
        block_on(activity.update(values! { "tone" => "green", "level" => 0.1 })).unwrap_err();
    assert_eq!(error.code(), "STALE_REVISION");
    assert_eq!(fake.lock().activities[0].revision, 9);
    assert_eq!(activity.revision(), Some(9));
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
    assert_eq!(fake.sent(Call::Update).len(), 4);
}

// AK-END-1, AK-END-2, AK-END-3, AK-END-4, AK-END-5, AK-UPDATE-7
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
    // The final content is the last accepted values at the next revision.
    assert_eq!(
        untimed(fake.sent(Call::End)[0].clone()),
        json!({"request":{"id":"la-fake-1","policy":{"kind":"immediate"},
            "snapshot":{"revision":1,"values":{"level":0.2,"tone":"green"}}}})
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

// AK-AUTH-2, AK-ERROR-1, AK-ERROR-3, AK-ERROR-4, AK-START-7, AK-START-8, AK-START-10
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
    fake.lock().fail_with = Some(
        json!({"code":"NOT_FOREGROUND","message":"ActivityKit refused a start outside the foreground (visibility)."}),
    );
    assert_eq!(
        block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap_err(),
        Error::NotForeground(
            "ActivityKit refused a start outside the foreground (visibility).".into()
        )
    );
    fake.lock().fail_with = Some(json!({"code":"SYSTEM_LIMIT","message":"x","scope":"app"}));
    assert_eq!(
        block_on(kit.activities()).unwrap_err(),
        Error::SystemLimit {
            scope: LimitScope::App
        }
    );
    fake.lock().fail_with = Some(json!({"code":"SYSTEM_LIMIT","message":"x","scope":"device"}));
    assert_eq!(
        block_on(kit.activities()).unwrap_err(),
        Error::SystemLimit {
            scope: LimitScope::Device
        }
    );
    fake.lock().fail_with = Some(
        json!({"code":"UNSUPPORTED_FEATURE","message":"x","feature":"transient","minimumIos":"18.0"}),
    );
    let feature = block_on(kit.activities()).unwrap_err();
    assert_eq!(
        feature,
        Error::UnsupportedFeature {
            feature: "transient".into(),
            minimum_ios: (18, 0)
        }
    );
    assert_eq!(
        feature.to_string(),
        "UNSUPPORTED_FEATURE: transient needs iOS 18.0"
    );
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

// AK-AUTH-3, AK-EVENT-1, AK-EVENT-5, AK-LIST-2
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
    fake.emit(json!({"type":"authorization","authorization":{"supported":true,"enabled":false,"buttons":true}}));
    for events in [first, second] {
        let Ok(Event::Action {
            activity: tapped,
            action,
            ..
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
            Ok(Event::Authorization(Authorization { enabled: false, .. }))
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

// AK-EVENT-3, AK-EVENT-4, AK-EVENT-7, AK-EVENT-11
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
    fake.emit(json!({"type":"authorization","authorization":{"supported":true,"enabled":true,"buttons":true}}));
    assert!(matches!(
        kit.events().try_recv(),
        Ok(Event::Authorization(Authorization { enabled: true, .. }))
    ));
}

// AK-EVENT-6
#[test]
fn a_tap_returns_once_every_subscriber_has_taken_it() {
    let fake = FakeBridge::default();
    let kit = ActivityKit::with_bridge(fake.clone(), Duration::from_secs(10));
    let events = kit.events();
    let taker = thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        let ready = Instant::now();
        // The event is dropped as soon as it is read.
        let tapped = matches!(events.recv_blocking().unwrap(), Event::Action { .. });
        (tapped, ready)
    });
    let started = Instant::now();
    fake.emit(json!({"type":"action","activityId":"la-1","actionId":"stop"}));
    let returned = Instant::now();
    let (tapped, ready) = taker.join().unwrap();
    assert!(tapped);
    // The tap returned after the receiver began to take it, and long before the wait was over.
    assert!(returned >= ready && returned - started < Duration::from_secs(5));
    // States and authorization changes do not wait.
    let _idle = kit.events();
    let started = Instant::now();
    fake.emit(json!({"type":"authorization","authorization":{"supported":true,"enabled":true,"buttons":true}}));
    assert!(started.elapsed() < Duration::from_secs(1));
}

// AK-EVENT-5, AK-EVENT-6
#[test]
fn the_wait_for_a_tap_is_bounded() {
    let fake = FakeBridge::default();
    let kit = ActivityKit::with_bridge(fake.clone(), Duration::from_millis(300));
    let idle = kit.events();
    let started = Instant::now();
    fake.emit(json!({"type":"action","activityId":"la-1","actionId":"stop"}));
    let waited = started.elapsed();
    // The wait, and not much more.
    assert!(
        waited >= Duration::from_millis(300) && waited < Duration::from_millis(550),
        "{waited:?}"
    );
    assert_eq!(idle.len(), 1);
    // A receiver dropped meanwhile does not hold the tap.
    drop(idle);
    let started = Instant::now();
    fake.emit(json!({"type":"action","activityId":"la-1","actionId":"stop"}));
    assert!(started.elapsed() < Duration::from_millis(100));
}

// AK-AUTH-1, AK-AUTH-2, AK-AUTH-4
#[test]
fn authorization_reads_the_bridge() {
    let (kit, fake) = kit();
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: true,
            enabled: true,
            buttons: true,
            frequent_pushes: false,
        }
    );
    fake.lock().authorization =
        Some(json!({"supported":true,"enabled":false,"buttons":false,"later":1}));
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: true,
            enabled: false,
            buttons: false,
            frequent_pushes: false
        }
    );
    fake.lock().authorization = Some(json!("broken"));
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: false,
            enabled: false,
            buttons: false,
            frequent_pushes: false
        }
    );
}

// AK-IMAGE-4, AK-IMAGE-5
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

// AK-HANDLE-2
#[test]
fn debug_output_names_the_activity_without_its_values() {
    let (kit, _fake) = kit();
    let activity = started(&kit);
    let debug = format!("{activity:?} {kit:?}");
    assert!(
        debug.contains(r#"id: "la-fake-1""#)
            && debug.contains("state: Active")
            && debug.contains("revision: Some(0)")
            && !debug.contains("green"),
        "{debug}"
    );
}

// AK-IMAGE-6, AK-KIT-2, AK-START-5, AK-START-7
#[cfg(not(target_os = "ios"))]
#[test]
fn off_ios_every_call_is_unsupported_after_the_contract_check() {
    let kit = ActivityKit::default();
    assert_eq!(
        kit.authorization(),
        Authorization {
            supported: false,
            enabled: false,
            buttons: false,
            frequent_pushes: false
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

// AK-LAYOUT-3
#[test]
fn bound_text_and_wire_values_round_trip() {
    let json: Json = serde_json::to_value(text(Bound::key("status"))).unwrap();
    assert_eq!(json, json!({"type":"text","bind":"status"}));
}

// AK-KIT-1, AK-THREAD-2
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

// AK-EVENT-2, AK-STATE-1, AK-STATE-2
#[test]
fn state_events_carry_every_state() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let events = kit.events();
    let states = [
        ("pending", State::Pending),
        ("active", State::Active),
        ("stale", State::Stale),
        ("ended", State::Ended),
        ("dismissed", State::Dismissed),
        ("unknown", State::Unknown),
    ];
    for (wire, state) in states {
        fake.emit(json!({"type":"state","activityId":"la-fake-1","activityKey":activity.key(),"state":wire}));
        let Ok(Event::State {
            activity: changed,
            state: reported,
        }) = events.try_recv()
        else {
            panic!("a state event for {wire}")
        };
        assert_eq!((changed, reported), (activity.clone(), state));
        assert_eq!(activity.state(), state, "the handle follows the event");
    }
    // A state this version does not know reads as Unknown.
    fake.emit(json!({"type":"state","activityId":"la-fake-1","activityKey":"k","state":"paused"}));
    assert!(matches!(
        events.try_recv(),
        Ok(Event::State {
            state: State::Unknown,
            ..
        })
    ));
}

// AK-AUTH-3, AK-EVENT-3, AK-EVENT-5
#[test]
fn every_receiver_gets_the_events_in_the_order_they_came() {
    let (kit, fake) = kit();
    let (first, second) = (kit.events(), kit.clone().events());
    let sequence = [
        json!({"type":"action","activityId":"la-1","actionId":"a"}),
        json!({"type":"authorization","authorization":{"supported":true,"enabled":false,"buttons":true}}),
        json!({"type":"state","activityId":"la-1","activityKey":"k","state":"stale"}),
        json!({"type":"action","activityId":"la-1","actionId":"b"}),
        json!({"type":"authorization","authorization":{"supported":true,"enabled":true,"buttons":true}}),
    ];
    for event in &sequence {
        fake.emit(event.clone());
    }
    let describe = |event: Event| match event {
        Event::Action { action, .. } => format!("action {action}"),
        Event::Authorization(authorization) => format!("authorization {}", authorization.enabled),
        Event::State { state, .. } => format!("state {state:?}"),
        _ => "other".into(),
    };
    for events in [first, second] {
        let order: Vec<_> = std::iter::from_fn(|| events.try_recv().ok())
            .map(describe)
            .collect();
        assert_eq!(
            order,
            [
                "action a",
                "authorization false",
                "state Stale",
                "action b",
                "authorization true"
            ]
        );
    }
}

// AK-BRIDGE-9, AK-THREAD-3
#[test]
fn dropping_a_future_does_not_cancel_its_request() {
    let (kit, fake) = kit();
    fake.lock().delay = Some(Duration::from_millis(30));
    let start = kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 });
    // Polled once, the request is on its way; then the caller loses interest.
    assert!(block_on(futures_lite::future::poll_once(Box::pin(start))).is_none());
    // The reply comes to a dropped receiver and goes nowhere, without a panic on the replying thread; the activity
    // runs, and the kit works on.
    fake.join();
    let listed = block_on(kit.activities()).unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].state(), State::Active);
    let update = listed[0].update(values! { "tone" => "red", "level" => 0.8 });
    assert!(block_on(futures_lite::future::poll_once(Box::pin(update))).is_none());
    fake.join();
    assert_eq!(fake.lock().activities[0].revision, 1);
}

// AK-HANDLE-1
#[test]
fn dropping_a_handle_never_ends_the_activity() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let clone = activity.clone();
    drop((activity, clone));
    assert!(fake.sent(Call::End).is_empty());
    assert_eq!(fake.lock().activities[0].state, State::Active);
    drop(kit);
    assert_eq!(fake.lock().activities[0].state, State::Active);
}

// AK-CUSTOM-3, AK-HANDLE-3
#[test]
fn degraded_features_come_from_the_record() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().activities[0].degraded = vec!["layout.custom.ring".into()];
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    assert_eq!(activity.degraded_features(), ["layout.custom.ring"]);
}

// AK-EVENT-8
#[test]
fn new_activities_arrive_as_started_events() {
    let (kit, fake) = kit();
    let events = kit.events();
    let activity = started(&kit);
    fake.emit(json!({"type":"started","activityId":"la-fake-1","activityKey":activity.key()}));
    fake.emit(json!({"type":"started","activityId":"la-ios-layout-push","activityKey":"pushed"}));
    let Ok(Event::Started { activity: first }) = events.try_recv() else {
        panic!("a started event")
    };
    assert_eq!(
        first, activity,
        "the app's own start gives the handle it holds"
    );
    let Ok(Event::Started { activity: other }) = events.try_recv() else {
        panic!("a started event")
    };
    assert_eq!(
        (other.id(), other.key(), other.revision()),
        ("la-ios-layout-push", "pushed", None)
    );
}

// AK-EVENT-9
#[test]
fn the_receiver_is_also_a_stream() {
    use futures_lite::StreamExt;
    let (kit, fake) = kit();
    // The receiver is not `Unpin`; pin it to poll it as a stream.
    let mut events = Box::pin(kit.events());
    fake.emit(json!({"type":"authorization","authorization":{"supported":true,"enabled":true,"buttons":true}}));
    let next = block_on(events.next());
    assert!(matches!(
        next,
        Some(Event::Authorization(Authorization { enabled: true, .. }))
    ));
}

// AK-UPDATE-11
#[test]
fn starts_updates_and_ends_carry_their_timestamp() {
    let (kit, fake) = kit();
    let before = millis(SystemTime::now()).unwrap();
    let activity = started(&kit);
    let update = Update::new(values! { "tone" => "red", "level" => 0.8 });
    block_on(activity.update_with(update)).unwrap();
    let after = millis(SystemTime::now()).unwrap();
    let explicit =
        Update::new(values! { "tone" => "red", "level" => 0.9 }).timestamp(at(1_790_000_000_000));
    block_on(activity.update_with(explicit)).unwrap();
    block_on(activity.end(End::immediately().timestamp(at(1_790_000_000_500)))).unwrap();
    let start = fake.sent(Call::Start)[0]["request"]["snapshot"]["timestamp"]
        .as_u64()
        .unwrap();
    let updates = fake.sent(Call::Update);
    let first = updates[0]["request"]["snapshot"]["timestamp"]
        .as_u64()
        .unwrap();
    assert!(
        (before..=after).contains(&start) && (before..=after).contains(&first),
        "{before} {start} {first} {after}"
    );
    assert_eq!(
        updates[1]["request"]["snapshot"]["timestamp"],
        1_790_000_000_000u64
    );
    assert_eq!(
        fake.sent(Call::End)[0]["request"]["snapshot"]["timestamp"],
        1_790_000_000_500u64
    );
    let other = started(&kit);
    let early = Update::new(values! {}).timestamp(UNIX_EPOCH - Duration::from_secs(1));
    assert_eq!(
        block_on(other.update_with(early)).unwrap_err().code(),
        "INVALID_INPUT"
    );
}

// AK-END-5, AK-END-6
#[test]
fn an_end_carries_its_final_content() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let end = End::immediately()
        .values(values! { "tone" => "gray", "level" => 1.0 })
        .stale_at(at(1_790_000_000_000))
        .relevance(10.0);
    block_on(activity.end(end)).unwrap();
    let [request] = fake.sent(Call::End).try_into().unwrap();
    let snapshot = &request["request"]["snapshot"];
    assert_eq!(request["request"]["policy"], json!({"kind":"immediate"}));
    assert_eq!(
        (snapshot["revision"].clone(), snapshot["values"].clone()),
        (json!(1), json!({"level":1.0,"tone":"gray"}))
    );
    assert_eq!(
        (snapshot["staleAt"].clone(), request["relevance"].clone()),
        (json!(1_790_000_000_000u64), json!(10.0))
    );
    assert_eq!(
        (activity.revision(), activity.state()),
        (Some(1), State::Ended)
    );
    assert_eq!(activity.values()["tone"], Value::from("gray"));
    // Without values the last accepted ones are the final content, at the next revision, without a stale date.
    let other = started(&kit);
    let dated =
        Update::new(values! { "tone" => "red", "level" => 0.5 }).stale_at(at(1_790_000_000_000));
    block_on(other.update_with(dated)).unwrap();
    block_on(other.end(End::default())).unwrap();
    let ended = &fake.sent(Call::End)[1]["request"]["snapshot"];
    assert_eq!(
        (ended["revision"].clone(), ended["values"].clone()),
        (json!(2), json!({"level":0.5,"tone":"red"}))
    );
    assert!(ended.get("staleAt").is_none());
    // Final content that breaks the contract never leaves Rust.
    let third = started(&kit);
    let too_many: Values = (0..33).map(|key| (format!("k{key}"), key)).collect();
    assert_eq!(
        block_on(third.end(End::immediately().values(too_many)))
            .unwrap_err()
            .code(),
        "INVALID_INPUT"
    );
    assert_eq!(
        block_on(third.end(End::immediately().relevance(f64::NAN)))
            .unwrap_err()
            .code(),
        "INVALID_INPUT"
    );
    assert_eq!(fake.sent(Call::End).len(), 2);
}

// AK-HANDLE-3, AK-UPDATE-12, AK-UPDATE-13
#[test]
fn relevance_is_kept_and_the_stale_date_follows_each_update() {
    let (kit, fake) = kit();
    let start = Start::new(sketch(), values! { "tone" => "green", "level" => 0.2 })
        .relevance(50.0)
        .stale_at(at(1_790_000_000_000));
    let activity = block_on(kit.start_with(start)).unwrap();
    assert_eq!(
        (activity.relevance(), activity.stale_at()),
        (50.0, Some(at(1_790_000_000_000)))
    );
    // An update without a relevance keeps the score; one without a stale date clears the date.
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    assert!(fake.sent(Call::Update)[0].get("relevance").is_none());
    assert_eq!((activity.relevance(), activity.stale_at()), (50.0, None));
    let scored = Update::new(values! { "tone" => "red", "level" => 0.9 }).relevance(80.0);
    block_on(activity.update_with(scored)).unwrap();
    assert_eq!(activity.relevance(), 80.0);
    // A start without a relevance scores 0, as ActivityKit does.
    assert_eq!(started(&kit).relevance(), 0.0);
}

// AK-BRIDGE-11
#[test]
fn a_call_the_bridge_never_answers_fails_after_the_call_wait() {
    let holding = HoldingBridge::default();
    holding.hold(true);
    let kit = ActivityKit::with_bridge_waits(
        holding.clone(),
        Duration::from_millis(20),
        Duration::from_millis(200),
    );
    let started = Instant::now();
    let error =
        block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap_err();
    assert!(matches!(error, Error::Native(_)), "{error:?}");
    let waited = started.elapsed();
    assert!(
        waited >= Duration::from_millis(200) && waited < Duration::from_secs(2),
        "{waited:?}"
    );
    // The reply that comes late reaches no one and panics nowhere.
    let late = holding.held().pop().expect("the kept reply");
    late(br#"{"ok":true,"data":[]}"#.to_vec());
    // The kit goes on: the next call waits again.
    assert!(matches!(
        block_on(kit.activities()).unwrap_err(),
        Error::Native(_)
    ));
    assert_eq!(holding.held().len(), 1);
}

// AK-BRIDGE-11
#[test]
fn the_call_wait_is_ten_seconds() {
    assert_eq!(CALL_WAIT, Duration::from_secs(10));
}
