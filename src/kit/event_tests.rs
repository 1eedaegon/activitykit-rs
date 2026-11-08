//! How events reach the receivers: the wait of a tap, receivers that come and go, and those that never read.

use super::*;
use crate::{events::TAP_WAIT, fake::FakeBridge, values};
use futures_lite::future::block_on;
use serde_json::{Value as Json, json};
use std::{
    sync::{Arc, Mutex},
    thread,
    time::Instant,
};

fn tap() -> Json {
    json!({"type":"action","activityId":"la-1","actionId":"stop"})
}

/// A kit whose taps wait up to `wait` for the receivers.
fn waiting(wait: Duration) -> (ActivityKit, FakeBridge) {
    let fake = FakeBridge::default();
    (ActivityKit::with_bridge(fake.clone(), wait), fake)
}

/// A thread that takes one event after `delay` and says when it began to take it: the event leaves its channel only
/// after that moment.
fn taker(
    events: async_channel::Receiver<Event>,
    delay: Duration,
) -> (thread::JoinHandle<()>, Arc<Mutex<Option<Instant>>>) {
    let ready = Arc::new(Mutex::new(None));
    let when = ready.clone();
    let thread = thread::spawn(move || {
        thread::sleep(delay);
        *when.lock().unwrap() = Some(Instant::now());
        events.recv_blocking().unwrap();
    });
    (thread, ready)
}

// AK-EVENT-6, AK-EVENT-14
#[test]
fn a_tap_waits_for_the_slowest_receiver() {
    let (kit, fake) = waiting(Duration::from_secs(10));
    let (fast, fast_ready) = taker(kit.events(), Duration::ZERO);
    let (slow, slow_ready) = taker(kit.events(), Duration::from_millis(150));
    fake.emit(tap());
    let returned = Instant::now();
    fast.join().unwrap();
    slow.join().unwrap();
    let slowest = slow_ready.lock().unwrap().unwrap();
    assert!(fast_ready.lock().unwrap().is_some());
    // The tap returned only after the slow receiver had begun to take it.
    assert!(
        returned >= slowest,
        "{:?}",
        slowest.saturating_duration_since(returned)
    );
}

// AK-EVENT-14
/// A handler that keeps the tap's event while it works holds the tap until it drops the event.
#[test]
fn a_tap_waits_until_its_event_is_dropped() {
    let (kit, fake) = waiting(Duration::from_secs(10));
    let events = kit.events();
    let handler = thread::spawn(move || {
        let event = events.recv_blocking().unwrap();
        assert!(matches!(event, Event::Action { .. }));
        thread::sleep(Duration::from_millis(150));
        let done = Instant::now();
        drop(event);
        done
    });
    let started = Instant::now();
    fake.emit(tap());
    let returned = Instant::now();
    let done = handler.join().unwrap();
    assert!(
        returned >= done && returned - started < Duration::from_secs(5),
        "returned {:?} before the handler was done",
        done.saturating_duration_since(returned)
    );
}

// AK-EVENT-14
/// `acknowledge()` lets the tap go while the app still keeps its event.
#[test]
fn acknowledging_releases_the_tap_before_the_event_is_dropped() {
    let (kit, fake) = waiting(Duration::from_secs(10));
    let events = kit.events();
    let (acknowledged, kept) = std::sync::mpsc::channel();
    let handler = thread::spawn(move || {
        let event = events.recv_blocking().unwrap();
        let Event::Action {
            ref acknowledgement,
            ..
        } = event
        else {
            panic!("a tap")
        };
        assert!(!acknowledgement.is_acknowledged());
        acknowledgement.acknowledge();
        assert!(acknowledgement.is_acknowledged());
        kept.recv().unwrap();
        drop(event);
    });
    let started = Instant::now();
    fake.emit(tap());
    assert!(started.elapsed() < Duration::from_secs(1));
    acknowledged.send(()).unwrap();
    handler.join().unwrap();
}

// AK-EVENT-14
/// A clone of the event holds the tap as the event does.
#[test]
fn a_tap_waits_for_every_clone_of_its_event() {
    let (kit, fake) = waiting(Duration::from_secs(10));
    let events = kit.events();
    let handler = thread::spawn(move || {
        let event = events.recv_blocking().unwrap();
        let kept = event.clone();
        drop(event);
        thread::sleep(Duration::from_millis(150));
        let done = Instant::now();
        drop(kept);
        done
    });
    fake.emit(tap());
    let returned = Instant::now();
    assert!(returned >= handler.join().unwrap());
}

// AK-EVENT-5, AK-EVENT-6
#[test]
fn a_receiver_dropped_while_a_tap_waits_releases_it() {
    let (kit, fake) = waiting(Duration::from_secs(3));
    let events = kit.events();
    let dropper = thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        drop(events);
    });
    let started = Instant::now();
    fake.emit(tap());
    let waited = started.elapsed();
    dropper.join().unwrap();
    assert!(
        waited >= Duration::from_millis(100) && waited < Duration::from_secs(1),
        "{waited:?}"
    );
}

// AK-EVENT-6
/// The intent posts a tap for at most 5 s (`ActivityKitActionIntent`); the hub must give up before.
#[test]
fn a_tap_waits_less_than_the_intent_posts_it() {
    const INTENT_POSTS_FOR: Duration = Duration::from_secs(5);
    assert!(TAP_WAIT + Duration::from_millis(500) <= INTENT_POSTS_FOR);
    assert!(TAP_WAIT >= Duration::from_secs(1));
}

// AK-EVENT-13
#[test]
fn an_unread_receiver_keeps_every_event_and_holds_each_tap_for_the_whole_wait() {
    let (kit, fake) = waiting(Duration::from_millis(100));
    let unread = kit.events();
    for _ in 0..3 {
        let started = Instant::now();
        fake.emit(tap());
        assert!(started.elapsed() >= Duration::from_millis(100));
    }
    assert_eq!(unread.len(), 3);
}

// AK-EVENT-6
/// Only taps wait: starts, states and authorization changes return at once, read or not.
#[test]
fn only_taps_wait_for_the_receivers() {
    let (kit, fake) = waiting(Duration::from_secs(3));
    let _unread = kit.events();
    for event in [
        json!({"type":"started","activityId":"la-1","activityKey":"k"}),
        json!({"type":"state","activityId":"la-1","activityKey":"k","state":"stale"}),
        json!({"type":"authorization","authorization":{"supported":true,"enabled":true,"buttons":true}}),
    ] {
        let started = Instant::now();
        fake.emit(event.clone());
        assert!(started.elapsed() < Duration::from_secs(1), "{event}");
    }
}

// AK-EVENT-11
#[test]
fn after_every_receiver_is_dropped_events_wait_for_the_next_one() {
    let (kit, fake) = waiting(Duration::from_millis(20));
    let (first, second) = (kit.events(), kit.events());
    drop((first, second));
    fake.emit(json!({"type":"authorization","authorization":{"supported":true,"enabled":false,"buttons":true}}));
    fake.emit(tap());
    let next = kit.events();
    assert!(matches!(
        next.try_recv(),
        Ok(Event::Authorization(Authorization { enabled: false, .. }))
    ));
    assert!(matches!(next.try_recv(), Ok(Event::Action { .. })));
}

// AK-AUTH-6
/// Authorization says what the device and Settings allow, not whether the app is set up: that is the start's answer.
#[test]
fn authorization_does_not_check_the_apps_setup() {
    let (kit, fake) = waiting(Duration::from_millis(20));
    assert!(kit.authorization().enabled);
    fake.lock().fail = Some((
        "CONFIGURATION_REQUIRED",
        "Embed a widget extension built from the layout template.",
    ));
    let start = kit.start(
        super::tests::sketch(),
        values! { "tone" => "green", "level" => 0.2 },
    );
    assert_eq!(
        block_on(start).unwrap_err().code(),
        "CONFIGURATION_REQUIRED"
    );
    assert!(kit.authorization().enabled);
}
