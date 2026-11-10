//! Writes of one activity: the order of revisions and timestamps, the final content of an end, retries, and the
//! limits of times.

use super::tests::{HoldingBridge, at, kit, sketch, started};
use super::*;
use crate::State;
use crate::{Value, values};
use futures_lite::future::{block_on, poll_once, zip};
use serde_json::json;
use std::{
    thread,
    time::{Duration, Instant},
};

const LARGEST: u64 = 8_640_000_000_000_000;

fn snapshots(fake: &crate::fake::FakeBridge, call: Call) -> Vec<serde_json::Value> {
    fake.sent(call)
        .into_iter()
        .map(|request| request["request"]["snapshot"].clone())
        .collect()
}

fn now() -> u64 {
    millis(SystemTime::now()).unwrap()
}

/// The output of `future` if it is ready within `limit`, so that a test fails where a broken queue would hang it.
fn within<T>(
    mut future: std::pin::Pin<&mut impl std::future::Future<Output = T>>,
    limit: Duration,
) -> Option<T> {
    let deadline = std::time::Instant::now() + limit;
    loop {
        if let Some(output) = block_on(poll_once(future.as_mut())) {
            return Some(output);
        }
        if std::time::Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(5));
    }
}

// AK-BRIDGE-9, AK-THREAD-3
#[test]
fn a_dropped_writes_reply_still_reaches_the_handle() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().delay = Some(Duration::from_millis(30));
    let update = activity.update(values! { "tone" => "red", "level" => 0.8 });
    assert!(block_on(poll_once(Box::pin(update))).is_none());
    fake.join();
    assert_eq!(activity.revision(), Some(1));
    assert_eq!(activity.values()["tone"], Value::from("red"));
}

// AK-END-5, AK-THREAD-3
#[test]
fn an_end_after_a_dropped_update_ends_with_that_updates_values() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().delay = Some(Duration::from_millis(30));
    let update = activity.update(values! { "tone" => "red", "level" => 0.8 });
    assert!(block_on(poll_once(Box::pin(update))).is_none());
    // The update is on its way and nobody waits for it; the end comes right after.
    block_on(activity.end(End::immediately())).unwrap();
    fake.join();
    let [ended] = snapshots(&fake, Call::End).try_into().unwrap();
    assert_eq!(
        (ended["revision"].clone(), ended["values"].clone()),
        (json!(2), json!({"level":0.8,"tone":"red"}))
    );
    assert_eq!(fake.lock().activities[0].values["tone"], Value::from("red"));
}

// AK-END-5, AK-UPDATE-3
#[test]
fn an_end_racing_an_update_ends_with_that_updates_values() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().delay = Some(Duration::from_millis(20));
    let (updated, ended) = block_on(zip(
        activity.update(values! { "tone" => "red", "level" => 0.8 }),
        activity.end(End::default()),
    ));
    updated.unwrap();
    ended.unwrap();
    fake.join();
    let [ended] = snapshots(&fake, Call::End).try_into().unwrap();
    assert_eq!(
        (ended["revision"].clone(), ended["values"].clone()),
        (json!(2), json!({"level":0.8,"tone":"red"}))
    );
    assert_eq!(activity.values()["tone"], Value::from("red"));
}

// AK-UPDATE-11, AK-UPDATE-14
#[test]
fn timestamps_are_taken_when_the_content_is_sent() {
    let (kit, fake) = kit();
    let start = Start::new(sketch(), values! { "tone" => "green", "level" => 0.2 });
    thread::sleep(Duration::from_millis(20));
    let before = now();
    let activity = block_on(kit.start_with(start)).unwrap();
    assert!(
        snapshots(&fake, Call::Start)[0]["timestamp"]
            .as_u64()
            .unwrap()
            >= before
    );
    // Built in one order and sent in the other: the timestamps follow the revisions.
    let first = Update::new(values! { "tone" => "red", "level" => 0.5 });
    thread::sleep(Duration::from_millis(20));
    let second = Update::new(values! { "tone" => "red", "level" => 0.6 });
    block_on(activity.update_with(second)).unwrap();
    block_on(activity.update_with(first)).unwrap();
    let stamps: Vec<_> = snapshots(&fake, Call::Update)
        .iter()
        .map(|snapshot| {
            (
                snapshot["revision"].as_u64().unwrap(),
                snapshot["timestamp"].as_u64().unwrap(),
            )
        })
        .collect();
    assert!(
        stamps[0].0 < stamps[1].0 && stamps[0].1 <= stamps[1].1,
        "{stamps:?}"
    );
    let end = End::immediately();
    thread::sleep(Duration::from_millis(20));
    let before = now();
    block_on(activity.end(end)).unwrap();
    assert!(
        snapshots(&fake, Call::End)[0]["timestamp"]
            .as_u64()
            .unwrap()
            >= before
    );
}

// AK-UPDATE-15
#[test]
fn a_failed_write_keeps_its_revision_reserved() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().fail = Some(("NATIVE_ERROR", "ActivityKit could not update the activity."));
    let error = block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap_err();
    assert_eq!(error.code(), "NATIVE_ERROR");
    assert_eq!(activity.revision(), Some(0));
    // The list still shows revision 0; revision 1 is never sent again.
    block_on(kit.activities()).unwrap();
    block_on(activity.update(values! { "tone" => "red", "level" => 0.9 })).unwrap();
    let revisions: Vec<_> = snapshots(&fake, Call::Update)
        .iter()
        .map(|snapshot| snapshot["revision"].as_u64().unwrap())
        .collect();
    assert_eq!(revisions, [1, 2]);
    assert_eq!(activity.revision(), Some(2));
}

// AK-UPDATE-4
#[test]
fn the_retry_after_a_stale_revision_compares_timestamps() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    // The shown content has the same timestamp as this update: it is not older, so no retry.
    fake.lock().activities[0].revision = 5;
    fake.lock().activities[0].timestamp = Some(1_790_000_000_000);
    let same =
        Update::new(values! { "tone" => "red", "level" => 0.8 }).timestamp(at(1_790_000_000_000));
    assert_eq!(
        block_on(activity.update_with(same)).unwrap_err().code(),
        "STALE_REVISION"
    );
    assert_eq!(fake.sent(Call::Update).len(), 1);
    // Shown content without a timestamp is older than any: the update is tried again.
    fake.lock().activities[0].revision = 9;
    fake.lock().activities[0].timestamp = None;
    block_on(activity.update(values! { "tone" => "red", "level" => 0.9 })).unwrap();
    let revisions: Vec<_> = snapshots(&fake, Call::Update)
        .iter()
        .map(|snapshot| snapshot["revision"].as_u64().unwrap())
        .collect();
    assert_eq!(revisions, [1, 6, 10]);
}

// AK-END-6, AK-UPDATE-4
#[test]
fn an_end_retries_once_after_a_stale_revision() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().activities[0].revision = 4;
    fake.lock().activities[0].timestamp = Some(1_000);
    block_on(activity.end(End::immediately().values(values! { "tone" => "gray", "level" => 1.0 })))
        .unwrap();
    let revisions: Vec<_> = snapshots(&fake, Call::End)
        .iter()
        .map(|snapshot| snapshot["revision"].as_u64().unwrap())
        .collect();
    assert_eq!(revisions, [1, 5]);
    assert_eq!(activity.state(), State::Ended);
    // A second failure after the retry is the answer.
    let other = started(&kit);
    fake.lock().fail_on.extend([
        (
            Call::End,
            "STALE_REVISION",
            "The revision is older than the current activity state.",
        ),
        (
            Call::End,
            "CONFLICT",
            "This revision already contains different state.",
        ),
    ]);
    // Made after the shown content, so the retry happens.
    let later = End::immediately().timestamp(SystemTime::now() + Duration::from_secs(60));
    let error = block_on(other.end(later)).unwrap_err();
    assert_eq!(
        error,
        Error::Conflict("This revision already contains different state.".into())
    );
    assert_eq!(fake.sent(Call::End).len(), 4);
}

// AK-END-3, AK-END-7
#[test]
fn an_end_after_takes_any_time_up_to_the_largest() {
    let (kit, fake) = kit();
    let far = SystemTime::now() + Duration::from_secs(30 * 24 * 3600);
    let past = SystemTime::now() - Duration::from_secs(60);
    for (when, label) in [(far, "far"), (past, "past"), (at(LARGEST), "largest")] {
        let activity = started(&kit);
        block_on(activity.end(End::after(when))).unwrap();
        let policy = fake.sent(Call::End).last().unwrap()["request"]["policy"].clone();
        assert_eq!(
            policy,
            json!({"kind":"after","at":millis(when).unwrap()}),
            "{label}"
        );
    }
    let activity = started(&kit);
    assert_eq!(
        block_on(activity.end(End::after(at(LARGEST + 1))))
            .unwrap_err()
            .code(),
        "INVALID_INPUT"
    );
}

// AK-END-7, AK-UPDATE-13
#[test]
fn times_beyond_the_largest_are_invalid_and_a_past_stale_date_is_not() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let past = SystemTime::now() - Duration::from_secs(3600);
    block_on(
        activity
            .update_with(Update::new(values! { "tone" => "red", "level" => 0.8 }).stale_at(past)),
    )
    .unwrap();
    assert_eq!(activity.stale_at(), Some(at(millis(past).unwrap())));
    let beyond = at(LARGEST + 1);
    let invalid = [
        block_on(activity.update_with(
            Update::new(values! { "tone" => "red", "level" => 0.8 }).stale_at(beyond),
        )),
        block_on(activity.update_with(
            Update::new(values! { "tone" => "red", "level" => 0.8 }).timestamp(beyond),
        )),
        block_on(activity.end(End::immediately().stale_at(beyond))),
        block_on(activity.end(End::immediately().timestamp(beyond))),
        block_on(kit.start_with(
            Start::new(sketch(), values! { "tone" => "green", "level" => 0.2 }).stale_at(beyond),
        ))
        .map(|_| ()),
    ];
    for result in invalid {
        assert_eq!(result.unwrap_err().code(), "INVALID_INPUT");
    }
    assert_eq!(fake.sent(Call::Update).len(), 1);
    assert!(fake.sent(Call::End).is_empty());
}

// AK-THREAD-1, AK-THREAD-2
/// `block_on` on worker threads, with replies from yet another thread, as the Swift layer answers from the main one.
#[test]
fn starts_from_eight_worker_threads_get_one_activity_each() {
    let (kit, fake) = kit();
    fake.lock().delay = Some(Duration::from_millis(10));
    let threads: Vec<_> = (0..8)
        .map(|index| {
            let kit = kit.clone();
            thread::spawn(move || {
                let values = values! { "tone" => "green", "level" => f64::from(index) / 10.0 };
                block_on(kit.start(sketch(), values))
                    .unwrap()
                    .id()
                    .to_owned()
            })
        })
        .collect();
    let mut ids: Vec<_> = threads
        .into_iter()
        .map(|thread| thread.join().unwrap())
        .collect();
    fake.join();
    ids.sort();
    ids.dedup();
    assert_eq!(ids.len(), 8);
    assert_eq!(fake.sent(Call::Start).len(), 8);
}

// AK-UPDATE-17
/// While a reply is on its way, within the call wait, the next write of the activity waits for it, and then goes out.
#[test]
fn a_held_reply_holds_every_later_write_until_it_comes() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().hold = true;
    let mut update = Box::pin(activity.update(values! { "tone" => "red", "level" => 0.8 }));
    assert!(block_on(poll_once(&mut update)).is_none());
    let mut end = Box::pin(activity.end(End::immediately()));
    for _ in 0..3 {
        assert!(block_on(poll_once(&mut end)).is_none());
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        fake.sent(Call::End).is_empty(),
        "the end waits for the update's answer"
    );
    fake.lock().hold = false;
    fake.release();
    block_on(update).unwrap();
    within(end.as_mut(), Duration::from_secs(2))
        .expect("the end goes out once the reply came")
        .unwrap();
    let [ended] = snapshots(&fake, Call::End).try_into().unwrap();
    assert_eq!(
        (ended["revision"].clone(), ended["values"].clone()),
        (json!(2), json!({"level":0.8,"tone":"red"}))
    );
}

// AK-BRIDGE-9, AK-UPDATE-17
/// A reply that never comes because the bridge dropped it (the kit going away) fails its write, and the next write
/// goes out.
#[test]
fn a_dropped_reply_fails_its_write_and_passes_the_turn_on() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    fake.lock().hold = true;
    let mut update = Box::pin(activity.update(values! { "tone" => "red", "level" => 0.8 }));
    assert!(block_on(poll_once(&mut update)).is_none());
    let mut end = Box::pin(activity.end(End::immediately()));
    assert!(block_on(poll_once(&mut end)).is_none());
    fake.lock().hold = false;
    let dropped = Instant::now();
    fake.drop_held();
    assert_eq!(block_on(update).unwrap_err().code(), "NATIVE_ERROR");
    assert!(
        dropped.elapsed() < Duration::from_secs(1),
        "a dropped reply fails its write at once, not after the call wait"
    );
    within(end.as_mut(), Duration::from_secs(2))
        .expect("the end goes out once the dropped reply let it")
        .unwrap();
    // The handle never learned the update's answer; its revision stays taken.
    let [ended] = snapshots(&fake, Call::End).try_into().unwrap();
    assert_eq!(ended["revision"], json!(2));
    assert_eq!(activity.state(), State::Ended);
}

// AK-UPDATE-3
/// The order of writes is the order in which their futures are first polled, not the order they were made.
#[test]
fn writes_go_out_in_the_order_their_futures_are_first_polled() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    let made_first = activity.update(values! { "tone" => "red", "level" => 0.1 });
    let made_second = activity.update(values! { "tone" => "red", "level" => 0.2 });
    let (second, first) = block_on(zip(made_second, made_first));
    second.unwrap();
    first.unwrap();
    let sent: Vec<_> = snapshots(&fake, Call::Update)
        .iter()
        .map(|snapshot| {
            (
                snapshot["revision"].clone(),
                snapshot["values"]["level"].clone(),
            )
        })
        .collect();
    assert_eq!(sent, [(json!(1), json!(0.2)), (json!(2), json!(0.1))]);
    assert_eq!(activity.values()["level"], Value::Number(0.1));
}

// AK-UPDATE-16
/// After an update older than the shown content, which ActivityKit (17.2) drops, the handle holds its values, and an
/// end without values carries them, made now: ActivityKit then shows them. `End::values` ends with others.
#[test]
fn an_end_without_values_after_an_older_update_carries_that_updates_values() {
    let (kit, fake) = kit();
    let activity = started(&kit);
    block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).unwrap();
    let hour_ago = SystemTime::now() - Duration::from_secs(3600);
    let old = Update::new(values! { "tone" => "gray", "level" => 0.1 }).timestamp(hour_ago);
    block_on(activity.update_with(old)).unwrap();
    assert_eq!(activity.values()["tone"], Value::from("gray"));
    block_on(activity.end(End::immediately())).unwrap();
    let [ended] = snapshots(&fake, Call::End).try_into().unwrap();
    assert_eq!(ended["values"], json!({"level":0.1,"tone":"gray"}));
    assert!(ended["timestamp"].as_u64().unwrap() > millis(hour_ago).unwrap());
}

// AK-BRIDGE-11
#[test]
fn a_write_the_bridge_never_answers_fails_after_the_call_wait_and_frees_the_turn() {
    let holding = HoldingBridge::default();
    let kit = ActivityKit::with_bridge_waits(
        holding.clone(),
        Duration::from_millis(20),
        Duration::from_millis(200),
    );
    let activity =
        block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap();
    holding.hold(true);
    let error = block_on(activity.update(values! { "tone" => "red", "level" => 0.5 })).unwrap_err();
    assert!(matches!(error, Error::Native(_)), "{error:?}");
    assert_eq!(
        activity.revision(),
        Some(0),
        "the content the kit gave up on is not the handle's"
    );

    // The turn is free: the next write goes out, at the next revision, and is answered.
    holding.hold(false);
    block_on(activity.update(values! { "tone" => "green", "level" => 0.9 })).unwrap();
    assert_eq!(activity.revision(), Some(2));
    assert_eq!(
        activity.values(),
        values! { "tone" => "green", "level" => 0.9 }
    );

    // The reply of the first write, come late with its content, is discarded.
    let late = holding.held().pop().expect("the kept reply");
    let record = json!({"ok": true, "data": {"id": activity.id(), "activityKey": activity.key(), "schemaVersion": 2,
        "snapshot": {"revision": 1, "values": {"tone": "red", "level": 0.5}}, "state": "active", "degradedFeatures": []}});
    late(record.to_string().into_bytes());
    assert_eq!(activity.revision(), Some(2));
    assert_eq!(
        activity.values(),
        values! { "tone" => "green", "level" => 0.9 }
    );
}

/// A kit on a holding bridge, with a started activity, whose calls wait 200 ms.
fn held(holding: &HoldingBridge) -> (ActivityKit, Activity) {
    let kit = ActivityKit::with_bridge_waits(
        holding.clone(),
        Duration::from_millis(20),
        Duration::from_millis(200),
    );
    let activity =
        block_on(kit.start(sketch(), values! { "tone" => "green", "level" => 0.2 })).unwrap();
    (kit, activity)
}

/// A record of `activity` as the bridge would reply it.
fn reply_of(activity: &Activity, revision: u64, tone: &str, state: &str) -> Vec<u8> {
    json!({"ok": true, "data": {"id": activity.id(), "activityKey": activity.key(), "schemaVersion": 2,
        "snapshot": {"revision": revision, "values": {"tone": tone, "level": 0.8}}, "state": state,
        "degradedFeatures": ["layout.island"]}})
    .to_string()
    .into_bytes()
}

// AK-BRIDGE-11
#[test]
fn a_reply_that_comes_after_the_wait_changes_nothing_of_the_handle() {
    let holding = HoldingBridge::default();
    let (_kit, activity) = held(&holding);
    holding.hold(true);
    assert!(block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).is_err());
    let late = holding.held().pop().expect("the kept reply");
    late(reply_of(&activity, 1, "red", "stale"));
    assert_eq!(activity.revision(), Some(0));
    assert_eq!(
        activity.values(),
        values! { "tone" => "green", "level" => 0.2 }
    );
    assert_eq!(activity.state(), State::Active);
    assert!(activity.degraded_features().is_empty());
}

// AK-BRIDGE-11
#[test]
fn a_late_reply_does_not_undo_an_end() {
    let holding = HoldingBridge::default();
    let (_kit, activity) = held(&holding);
    holding.hold(true);
    assert!(block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).is_err());
    let late = holding.held().pop().expect("the kept reply");
    holding.hold(false);
    block_on(activity.end(End::immediately())).unwrap();
    assert_eq!(
        (activity.state(), activity.revision()),
        (State::Ended, Some(2))
    );
    late(reply_of(&activity, 1, "red", "active"));
    assert_eq!(
        (activity.state(), activity.revision()),
        (State::Ended, Some(2))
    );
    assert_eq!(activity.values()["tone"], Value::Text("green".into()));
}

// AK-BRIDGE-11
#[test]
fn a_late_reply_does_not_free_the_turn_of_the_write_in_flight() {
    let holding = HoldingBridge::default();
    let (_kit, activity) = held(&holding);
    holding.hold(true);
    assert!(block_on(activity.update(values! { "tone" => "red", "level" => 0.8 })).is_err());
    let late = holding.held().pop().expect("the kept reply");
    // The end has the turn and waits for its reply; the next update waits for the end.
    let mut end = Box::pin(activity.end(End::immediately()));
    assert!(block_on(poll_once(&mut end)).is_none());
    let end_reply = holding.held().pop().expect("the end went out");
    let mut next = Box::pin(activity.update(values! { "tone" => "blue", "level" => 0.9 }));
    assert!(block_on(poll_once(&mut next)).is_none());
    late(reply_of(&activity, 1, "red", "active"));
    thread::sleep(Duration::from_millis(50));
    assert!(
        block_on(poll_once(&mut next)).is_none(),
        "the update still waits for the end"
    );
    assert!(holding.held().is_empty(), "the update was not sent");
    end_reply(reply_of(&activity, 2, "green", "ended"));
    within(end.as_mut(), Duration::from_secs(2))
        .expect("the end answers")
        .unwrap();
    assert_eq!(activity.state(), State::Ended);
    // Now the update goes out, and waits for its own reply.
    assert!(block_on(poll_once(&mut next)).is_none());
    assert_eq!(holding.held().len(), 1, "the update went out after the end");
}
