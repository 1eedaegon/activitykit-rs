//! The scenarios of the iOS test host, in plain Rust: no UI framework, no async runtime. The host app (App/Host.swift)
//! calls `ak_host_run` once it is in the foreground; the scenario named by the launch arguments `-scenario <name>`
//! runs on a thread of its own, driving futures with `futures_lite::future::block_on`, which is fine off the main
//! thread. Every step is a line for the UI test, which reads the last one: `<step>`, then `PASS <scenario>` or
//! `FAIL <scenario>: <reason>`.

use activitykit::{
    Activity, ActivityKit, Bound, End, Error, Event, Layout, Push, Receipts, Start, State, Style,
    Update, Value,
    layout::{
        ButtonStyle, Font, Frame, ImageSource, IndicatorKind, button, custom, divider, gauge,
        hstack, image, path, progress, spacer, symbol, text, timer, vstack, zstack,
    },
    values,
};
use futures_lite::future::{block_on, poll_once};
use std::{
    io::Write,
    thread,
    time::{Duration, Instant, SystemTime},
};

/// Set by the host app once it is in the background (App/Host.swift).
static IN_BACKGROUND: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The host app calls this when it entered the background.
#[unsafe(no_mangle)]
pub extern "C" fn ak_host_entered_background() {
    IN_BACKGROUND.store(true, std::sync::atomic::Ordering::SeqCst);
}

/// When the host app saw the intent of a tap acknowledged (App/Host.swift): the intent returns right after.
static TAP_ACKNOWLEDGED: std::sync::Mutex<Option<Instant>> = std::sync::Mutex::new(None);

/// The host app calls this when the acknowledgement of a tap's intent is complete.
#[unsafe(no_mangle)]
pub extern "C" fn ak_host_tap_acknowledged() {
    let mut acknowledged = TAP_ACKNOWLEDGED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    acknowledged.get_or_insert_with(Instant::now);
}

/// Hands one line to the host app; `bytes` lives only during the call.
type Report = extern "C" fn(bytes: *const u8, len: usize);

struct Reporter(Report);

impl Reporter {
    fn say(&self, line: impl Into<String>) {
        let line = line.into();
        println!("[activitykit-host] {line}");
        if let Some(home) = std::env::var_os("HOME") {
            let path = std::path::Path::new(&home).join("Documents/activitykit-host.log");
            if let Ok(mut file) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                let _ = writeln!(file, "{line}");
            }
        }
        (self.0)(line.as_ptr(), line.len());
    }
}

type Outcome = Result<(), String>;

fn check(condition: bool, what: impl Into<String>) -> Outcome {
    if condition { Ok(()) } else { Err(what.into()) }
}

/// Runs the scenario of the launch arguments on a new thread and returns at once.
#[unsafe(no_mangle)]
pub extern "C" fn ak_host_run(report: Report) {
    let arguments: Vec<String> = std::env::args().collect();
    let scenario = arguments
        .iter()
        .position(|argument| argument == "-scenario")
        .and_then(|index| arguments.get(index + 1))
        .cloned()
        .unwrap_or_default();
    thread::spawn(move || {
        let reporter = Reporter(report);
        // A launch by the system for a tap has no scenario: the start of the cold-tap scenario left its mark.
        let scenario = if scenario.is_empty() && cold_tap_pending() {
            "cold-tap".to_owned()
        } else {
            scenario
        };
        if scenario.is_empty() {
            reporter.say("idle: launch with -scenario lockscreen, relaunch-start, relaunch-check, push-start or cold-tap-start");
            return;
        }
        let outcome = match scenario.as_str() {
            "lockscreen" => lock_screen(&reporter),
            "relaunch-start" => relaunch_start(&reporter),
            "relaunch-check" => relaunch_check(&reporter),
            "background-start" => background_start(&reporter),
            "every-node" => every_node(&reporter),
            "policies" => policies(&reporter),
            "redacted-start" => redacted_start(&reporter),
            "redacted-check" => redacted_check(&reporter),
            "push-start" => push_start(&reporter),
            "cold-tap-start" => cold_tap_start(&reporter),
            "cold-tap" => cold_tap(&reporter),
            other => Err(format!("no scenario {other}")),
        };
        match outcome {
            Ok(()) => reporter.say(format!("PASS {scenario}")),
            Err(reason) => reporter.say(format!("FAIL {scenario}: {reason}")),
        }
    });
}

/// A recording status whose color, like the level bar and the Stop button, is bound to the value `tone`.
fn layout() -> Layout {
    Layout::new(
        vstack([
            hstack([
                symbol("mic.fill").style("status"),
                text(Bound::key("status")).style("status"),
                spacer(),
                button("stop", text("Stop")).style("stop"),
            ])
            .spacing(8.0),
            progress("level").style("level"),
            // No view is registered under this name: it draws nothing and is reported as degraded.
            custom("ring").prop("level", Bound::key("level")),
        ])
        .spacing(10.0),
    )
    .style(
        "status",
        Style::new().font(Font::Headline).color(Bound::key("tone")),
    )
    .style("level", Style::new().tint(Bound::key("tone")))
    .style(
        "stop",
        Style::new()
            .button_style(ButtonStyle::BorderedProminent)
            .tint(Bound::key("tone")),
    )
}

/// The kit, with Live Activities on, and no activity left from an earlier run.
fn prepared(reporter: &Reporter) -> Result<ActivityKit, String> {
    cleared(reporter, ActivityKit::new())
}

/// `kit`, with Live Activities on, and no activity left from an earlier run.
fn cleared(reporter: &Reporter, kit: ActivityKit) -> Result<ActivityKit, String> {
    let authorization = kit.authorization();
    reporter.say(format!("authorization {authorization:?}"));
    check(authorization.enabled, "Live Activities are not enabled")?;
    for activity in block_on(kit.activities()).map_err(|error| error.to_string())? {
        if matches!(activity.state(), State::Active | State::Stale) {
            block_on(activity.end(End::immediately())).map_err(|error| error.to_string())?;
            reporter.say(format!("ended a leftover {}", activity.id()));
        }
    }
    Ok(kit)
}

/// The first value `probe` gives within `limit`, asked every 200 ms.
fn wait_until<T>(limit: Duration, mut probe: impl FnMut() -> Option<T>) -> Option<T> {
    let deadline = Instant::now() + limit;
    loop {
        if let Some(found) = probe() {
            return Some(found);
        }
        if Instant::now() >= deadline {
            return None;
        }
        thread::sleep(Duration::from_millis(200));
    }
}

/// The activity as `activities()` lists it now.
fn listed(kit: &ActivityKit, activity: &Activity) -> Result<Option<Activity>, String> {
    let all = block_on(kit.activities()).map_err(|error| format!("activities: {error}"))?;
    Ok(all.into_iter().find(|listed| listed == activity))
}

/// The next event that `accept` takes, within `limit`.
fn next_event<T>(
    events: &activitykit::async_channel::Receiver<Event>,
    limit: Duration,
    accept: impl Fn(Event) -> Option<T>,
) -> Option<T> {
    let deadline = Instant::now() + limit;
    while Instant::now() < deadline {
        match events.try_recv() {
            Ok(event) => {
                if let Some(found) = accept(event) {
                    return Some(found);
                }
            }
            Err(_) => thread::sleep(Duration::from_millis(50)),
        }
    }
    None
}

/// The start of the recording scenarios under `key`; the same each time it is made.
fn first_start(key: &str) -> activitykit::Start {
    let first = values! { "status" => "Recording", "tone" => "green", "level" => 0.2 };
    activitykit::Start::new(layout(), first)
        .key(key)
        .relevance(50.0)
}

/// AK-START-3: the same keyed start, made again now, returns the running activity.
fn starts_again(kit: &ActivityKit, start: activitykit::Start, running: &Activity) -> Outcome {
    let again = block_on(kit.start_with(start)).map_err(|error| format!("start again: {error}"))?;
    check(
        again == *running && again.revision() == running.revision(),
        format!(
            "the same keyed start returns {}, got {}",
            running.id(),
            again.id()
        ),
    )
}

fn start(kit: &ActivityKit, reporter: &Reporter, key: &str) -> Result<Activity, String> {
    let activity =
        block_on(kit.start_with(first_start(key))).map_err(|error| format!("start: {error}"))?;
    check(
        activity.revision() == Some(0) && activity.key() == key,
        "the start's record",
    )?;
    reporter.say(format!("started {}", activity.id()));
    let update = Update::new(values! { "status" => "Too loud", "tone" => "red", "level" => 0.8 });
    block_on(activity.update_with(update)).map_err(|error| format!("update: {error}"))?;
    check(activity.revision() == Some(1), "the update's revision")?;
    // AK-UPDATE-12: an update without a relevance keeps the score.
    check(
        activity.relevance() == 50.0,
        format!("the kept relevance, got {}", activity.relevance()),
    )?;
    check(
        activity.values().get("tone") == Some(&Value::from("red")),
        "the update's values",
    )?;
    Ok(activity)
}

/// Start, turn the bound color red, wait for the Stop button on the Lock Screen (the UI test taps it), then end.
// AK-AUTH-1, AK-CUSTOM-3, AK-END-1, AK-END-6, AK-EVENT-1, AK-EVENT-2, AK-EVENT-8, AK-EVENT-14, AK-HANDLE-3, AK-KIT-1, AK-START-1, AK-STATE-2, AK-THREAD-2, AK-UPDATE-1, AK-UPDATE-5, AK-UPDATE-11, AK-UPDATE-12, AK-UPDATE-16
fn lock_screen(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let events = kit.events();
    let activity = start(&kit, reporter, "host:lockscreen")?;
    // AK-UPDATE-16: content made an hour before the shown one. The call succeeds, ActivityKit (iOS 17.2) drops it: the
    // UI test finds "Too loud" on the Lock Screen and no "Old news".
    let old = Update::new(values! { "status" => "Old news", "tone" => "green", "level" => 0.1 })
        .timestamp(SystemTime::now() - Duration::from_secs(3600));
    block_on(activity.update_with(old)).map_err(|error| format!("old update: {error}"))?;
    check(activity.revision() == Some(2), "the old update's revision")?;
    // AK-KIT-1: every kit of the process talks to the same Swift layer.
    let seen = block_on(ActivityKit::new().activities())
        .map_err(|error| format!("activities: {error}"))?;
    check(seen.contains(&activity), "a second kit lists the activity")?;
    // AK-CUSTOM-3: the app registers no custom views, so the custom node is reported.
    check(
        activity.degraded_features() == ["layout.custom.ring"],
        format!("degraded features {:?}", activity.degraded_features()),
    )?;
    // AK-UPDATE-12: ActivityKit itself kept the score.
    let shown = listed(&kit, &activity)?.map(|listed| listed.relevance());
    check(
        shown == Some(50.0),
        format!("ActivityKit's relevance after the update: {shown:?}"),
    )?;
    // AK-EVENT-8: the start arrived as a new activity, the handle the app holds.
    let began = next_event(&events, Duration::from_secs(10), |event| match event {
        Event::Started { activity: new, .. } if new == activity => Some(()),
        _ => None,
    });
    check(began.is_some(), "the start arrives as Event::Started")?;
    // AK-EVENT-2: ActivityKit reports the new activity active.
    let active = next_event(&events, Duration::from_secs(10), |event| match event {
        Event::State {
            activity: changed,
            state,
            ..
        } if changed == activity && state == State::Active => Some(()),
        _ => None,
    });
    check(active.is_some(), "ActivityKit reports the activity active")?;
    reporter.say("updated: tap Stop on the Lock Screen");
    let tapped = next_event(&events, Duration::from_secs(180), |event| match event {
        Event::Action {
            activity,
            action,
            acknowledgement,
            ..
        } => Some((activity, action, acknowledgement)),
        _ => None,
    });
    let (tapped, action, acknowledgement) = tapped.ok_or("no tap within 3 minutes")?;
    reporter.say(format!("action {action} from {}", tapped.id()));
    // AK-EVENT-14: the handler updates the activity and takes a second in all, holding the acknowledgement; the tap's
    // intent waits for it.
    let stopping = values! { "status" => "Stopping", "tone" => "gray", "level" => 1.0 };
    block_on(tapped.update(stopping)).map_err(|error| format!("update in the handler: {error}"))?;
    thread::sleep(Duration::from_secs(1));
    let early = *TAP_ACKNOWLEDGED
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    check(
        early.is_none(),
        "the intent was acknowledged while the handler still worked",
    )?;
    let handled = Instant::now();
    drop(acknowledgement);
    let acknowledged = wait_until(Duration::from_secs(5), || {
        *TAP_ACKNOWLEDGED
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    })
    .ok_or("the intent of the tap was never acknowledged")?;
    check(
        acknowledged >= handled,
        "the intent was acknowledged before the handler was done",
    )?;
    reporter.say(format!(
        "the intent was acknowledged {:?} after the handler (an update and 1 s) was done",
        acknowledged - handled
    ));
    check(
        action == "stop" && tapped == activity,
        "the tap names the button and the activity",
    )?;
    check(
        tapped.revision() == Some(3) && activity.revision() == Some(3),
        "the tapped handle shares the started one's revision, and the handler's update",
    )?;
    // AK-END-6: the end carries its final values.
    let last = End::immediately()
        .values(values! { "status" => "Stopped", "tone" => "gray", "level" => 1.0 });
    block_on(tapped.end(last)).map_err(|error| format!("end: {error}"))?;
    check(activity.state() == State::Ended, "the record of the end")?;
    check(
        activity.revision() == Some(4)
            && activity.values().get("status") == Some(&Value::from("Stopped")),
        "the end shows its final values",
    )?;
    reporter.say(format!("ended {}", activity.id()));
    let gone = next_event(&events, Duration::from_secs(10), |event| match event {
        Event::State {
            activity: changed,
            state,
            ..
        } if changed == activity && state == State::Dismissed => Some(()),
        _ => None,
    });
    check(gone.is_some(), "ActivityKit reports the activity dismissed")?;
    reporter.say("state dismissed");
    Ok(())
}

/// The mark the start of the cold-tap scenario leaves for the launch the tap causes.
fn cold_tap_mark() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME")
        .map(|home| std::path::Path::new(&home).join("Documents/activitykit-host-cold-tap"))
}

fn cold_tap_pending() -> bool {
    cold_tap_mark().is_some_and(|mark| mark.exists())
}

// AK-PUSH-1, AK-PUSH-6
/// Without the Push Notifications capability and APNs (the simulator) ActivityKit refuses a start that asks for a
/// push token with a permissions error: the start fails with `ConfigurationRequired` and leaves no activity. The app's
/// own update of a plain activity does not come back as `Event::Updated`.
fn push_start(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let events = kit.events();
    let asked = Instant::now();
    let token = Start::new(
        layout(),
        values! { "status" => "Pushing", "tone" => "green", "level" => 0.3 },
    )
    .key("host:push:token")
    .push(Push::Token);
    let refused = block_on(kit.start_with(token));
    let waited = asked.elapsed();
    reporter.say(format!(
        "a start with Push::Token answered {refused:?} after {waited:?}"
    ));
    check(
        matches!(refused, Err(Error::ConfigurationRequired(_))),
        "without the capability and APNs a start with Push::Token fails with ConfigurationRequired",
    )?;
    let _ = waited;
    let left: Vec<_> = block_on(kit.activities())
        .map_err(|error| format!("activities: {error}"))?
        .into_iter()
        .filter(|activity| activity.key() == "host:push:token")
        .collect();
    for activity in &left {
        let _ = block_on(activity.end(End::immediately()));
    }
    check(
        left.is_empty(),
        format!(
            "ActivityKit started {} activities for the request it never answered",
            left.len()
        ),
    )?;
    let plain = Start::new(
        layout(),
        values! { "status" => "Pushing", "tone" => "green", "level" => 0.3 },
    )
    .key("host:push");
    let activity = block_on(kit.start_with(plain)).map_err(|error| format!("start: {error}"))?;
    reporter.say(format!("started {} without a push", activity.id()));
    block_on(activity.update(values! { "status" => "Updated", "tone" => "red", "level" => 0.6 }))
        .map_err(|error| format!("update: {error}"))?;
    // ActivityKit reports the app's own content back (`contentUpdates`); the handle, which sent it, says nothing.
    let repeated = next_event(&events, Duration::from_secs(3), |event| match event {
        Event::Updated {
            activity: changed, ..
        } if changed == activity => Some(()),
        _ => None,
    });
    check(
        repeated.is_none(),
        "the app's own update came back as Event::Updated",
    )?;
    check(
        activity.revision() == Some(1)
            && activity.values().get("status") == Some(&Value::from("Updated")),
        "the handle holds the app's content",
    )?;
    block_on(activity.end(End::immediately())).map_err(|error| format!("end: {error}"))?;
    reporter.say("the update came back from ActivityKit and was not reported again");
    Ok(())
}

// AK-EVENT-15
/// Starts an activity with a button and leaves its mark; the UI test then kills the app and taps the button.
fn cold_tap_start(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let start = Start::new(
        layout(),
        values! { "status" => "Waiting", "tone" => "green", "level" => 0.2 },
    )
    .key("host:cold-tap");
    let activity = block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
    let mark = cold_tap_mark().ok_or("no HOME")?;
    std::fs::write(&mark, activity.id()).map_err(|error| format!("mark: {error}"))?;
    reporter.say(format!(
        "running {}: terminate the app, then tap Stop",
        activity.id()
    ));
    Ok(())
}

/// The launch the tap caused: the kit is made at once, the tap arrives, the handler updates the activity and the
/// intent is acknowledged after it.
// AK-EVENT-15
fn cold_tap(reporter: &Reporter) -> Outcome {
    let launched = Instant::now();
    if let Some(mark) = cold_tap_mark() {
        let _ = std::fs::remove_file(mark);
    }
    let kit = ActivityKit::new();
    let events = kit.events();
    reporter.say("launched without a scenario: waiting for the tap");
    let tapped = next_event(&events, Duration::from_secs(20), |event| match event {
        Event::Action {
            activity,
            action,
            acknowledgement,
            ..
        } => Some((activity, action, acknowledgement)),
        _ => None,
    });
    let (activity, action, acknowledgement) = tapped.ok_or("no tap within 20 s of the launch")?;
    let after = launched.elapsed();
    reporter.say(format!(
        "action {action} from {} {after:?} after the launch",
        activity.id()
    ));
    check(action == "stop", format!("the action is {action}"))?;
    check(
        activity.key() == "host:cold-tap",
        format!("the tap names the activity {}", activity.id()),
    )?;
    block_on(activity.update(values! { "status" => "Launched", "tone" => "gray", "level" => 1.0 }))
        .map_err(|error| format!("update in the handler: {error}"))?;
    thread::sleep(Duration::from_millis(500));
    let handled = Instant::now();
    drop(acknowledgement);
    let acknowledged = wait_until(Duration::from_secs(5), || {
        *TAP_ACKNOWLEDGED
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    })
    .ok_or("the intent of the tap was never acknowledged")?;
    check(
        acknowledged >= handled,
        "the intent was acknowledged before the handler was done",
    )?;
    reporter.say(
        "the handler updated the activity to Launched and the intent was acknowledged after it",
    );
    Ok(())
}

// AK-START-3
/// Start and update an activity, then the UI test ends the process.
fn relaunch_start(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let activity = start(&kit, reporter, "host:relaunch")?;
    starts_again(&kit, first_start("host:relaunch"), &activity)?;
    reporter.say(format!(
        "running {} at revision 1: terminate the app",
        activity.id()
    ));
    Ok(())
}

/// After a relaunch, find the activity, continue its revision, and end it.
// AK-HANDLE-1, AK-HANDLE-3, AK-KIT-4, AK-LIST-1, AK-START-3, AK-STATE-3
fn relaunch_check(reporter: &Reporter) -> Outcome {
    let kit = ActivityKit::new();
    let activities = block_on(kit.activities()).map_err(|error| format!("activities: {error}"))?;
    let activity = activities
        .into_iter()
        .find(|activity| activity.key() == "host:relaunch" && activity.state() == State::Active)
        .ok_or("no running activity with the key host:relaunch")?;
    reporter.say(format!(
        "found {} at revision {:?}",
        activity.id(),
        activity.revision()
    ));
    check(
        activity.revision() == Some(1),
        "the accepted revision survives the relaunch",
    )?;
    check(
        activity.values().get("tone") == Some(&Value::from("red")),
        "the accepted values survive the relaunch",
    )?;
    // AK-HANDLE-3: the content's timestamp comes back too.
    check(
        activity.timestamp().is_some(),
        "the content's timestamp survives the relaunch",
    )?;
    // AK-KIT-4: the lookup by id gives the handle the list gave.
    let found =
        block_on(kit.activity(activity.id())).map_err(|error| format!("activity: {error}"))?;
    check(
        found.as_ref() == Some(&activity),
        "activity(id) finds the listed handle",
    )?;
    // AK-START-3: after the relaunch the same keyed start still returns the running activity.
    starts_again(&kit, first_start("host:relaunch"), &activity)?;
    let update = values! { "status" => "Quiet again", "tone" => "green", "level" => 0.1 };
    block_on(activity.update(update)).map_err(|error| format!("update: {error}"))?;
    check(
        activity.revision() == Some(2),
        "the restored handle continues the revision",
    )?;
    block_on(activity.end(End::immediately())).map_err(|error| format!("end: {error}"))?;
    reporter.say(format!("updated to revision 2 and ended {}", activity.id()));
    Ok(())
}

/// How long the background scenario keeps trying a start, and how often.
const REFUSAL_WITHIN: Duration = Duration::from_secs(20);
const RETRY_EVERY: Duration = Duration::from_secs(1);

// AK-START-10, AK-START-11
/// The UI test sends the app to the background, then this tries a start every second. ActivityKit treats the app as
/// visible for a short while after it left the foreground, so the first attempts may succeed (each such activity is
/// ended at once); the scenario passes at the first refusal, `NotForeground` from `visibility`, and fails if none comes
/// within 20 s.
fn background_start(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    reporter.say("waiting: send the app to the background");
    let deadline = Instant::now() + Duration::from_secs(60);
    while !IN_BACKGROUND.load(std::sync::atomic::Ordering::SeqCst) {
        check(
            Instant::now() < deadline,
            "the app never went to the background",
        )?;
        thread::sleep(Duration::from_millis(100));
    }
    let left = Instant::now();
    for attempt in 1.. {
        let start = activitykit::Start::new(
            layout(),
            values! { "status" => "Late", "tone" => "green", "level" => 0.1 },
        );
        let tried = left.elapsed();
        match block_on(kit.start_with(start)) {
            Err(Error::NotForeground(message)) => {
                reporter.say(format!(
                    "not in the foreground at attempt {attempt}, {tried:.1?} after the background signal: {message}"
                ));
                return Ok(());
            }
            Err(error) => return Err(format!("expected NotForeground, got {error}")),
            Ok(activity) => {
                block_on(activity.end(End::immediately())).map_err(|error| {
                    format!("ending the activity of attempt {attempt}: {error}")
                })?;
                reporter.say(format!(
                    "attempt {attempt}, {tried:.1?} after the background signal: started, and ended"
                ));
            }
        }
        if left.elapsed() + RETRY_EVERY > REFUSAL_WITHIN {
            return Err(format!(
                "no start was refused within {REFUSAL_WITHIN:?} of the background signal ({attempt} attempts)"
            ));
        }
        thread::sleep(RETRY_EVERY);
    }
    unreachable!("the attempts end with a return")
}

// AK-RENDER-16
/// Every node type of the contract in one layout: the widget draws it on the Lock Screen, and its button works.
fn every_node(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let events = kit.events();
    let layout = Layout::new(
        vstack([
            hstack([
                symbol("star.fill").variable("level"),
                text("Every node"),
                spacer().min_length(4.0),
                timer("from", "to").style("digits"),
            ])
            .spacing(6.0),
            hstack([
                progress("level"),
                gauge("level").kind(IndicatorKind::Circular),
                path("M0 0 L10 10 L20 0 Z", [20.0, 10.0]).stroke(2.0),
            ])
            .spacing(6.0),
            zstack([divider(), image(ImageSource::asset("none")).resizable()]),
            hstack([
                button("tap", text("Tap")),
                custom("ring").prop("level", Bound::key("level")),
            ]),
        ])
        .spacing(6.0),
    )
    .style(
        "digits",
        Style::new()
            .monospaced_digit()
            .frame(Frame::new().width(64.0)),
    );
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|error| error.to_string())?
        .as_millis() as u64;
    let values = values! { "level" => 0.5, "from" => now, "to" => now + 600_000 };
    let activity =
        block_on(kit.start(layout, values)).map_err(|error| format!("start: {error}"))?;
    reporter.say("shown: tap Tap on the Lock Screen");
    let tapped = next_event(&events, Duration::from_secs(180), |event| match event {
        Event::Action {
            activity, action, ..
        } => Some((activity, action)),
        _ => None,
    });
    let (tapped, action) = tapped.ok_or("no tap within 3 minutes")?;
    check(
        action == "tap" && tapped == activity,
        "the tap names the button and the activity",
    )?;
    block_on(activity.end(End::immediately())).map_err(|error| format!("end: {error}"))?;
    reporter.say(format!("ended {}", activity.id()));
    Ok(())
}

/// A layout without buttons: the ended activities that this scenario leaves on the Lock Screen take no taps.
fn plain() -> Layout {
    Layout::new(vstack([text("Policy check"), text(Bound::key("status"))]).spacing(4.0))
}

fn start_plain(kit: &ActivityKit, start: activitykit::Start) -> Result<Activity, String> {
    block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))
}

/// The outcome of several checks: each one is reported, and the scenario fails at the end if one failed.
struct Checks<'a> {
    reporter: &'a Reporter,
    failed: Vec<String>,
}

impl Checks<'_> {
    fn check(&mut self, condition: bool, what: impl Into<String>) {
        let what = what.into();
        self.reporter
            .say(format!("{} {what}", if condition { "ok" } else { "not" }));
        if !condition {
            self.failed.push(what);
        }
    }

    fn outcome(self) -> Outcome {
        if self.failed.is_empty() {
            Ok(())
        } else {
            Err(self.failed.join("; "))
        }
    }
}

/// The state of `activity` that an event or the list reports first, within `limit`.
fn reaches(
    kit: &ActivityKit,
    events: &activitykit::async_channel::Receiver<Event>,
    activity: &Activity,
    state: State,
    limit: Duration,
) -> Option<&'static str> {
    wait_until(limit, || {
        while let Ok(event) = events.try_recv() {
            if let Event::State {
                activity: changed,
                state: reported,
                ..
            } = event
                && changed == *activity
                && reported == state
            {
                return Some("event");
            }
        }
        match listed(kit, activity) {
            Ok(Some(shown)) if shown.state() == state => Some("list"),
            Ok(None) if state == State::Dismissed => Some("gone from the list"),
            _ => None,
        }
    })
}

/// What ActivityKit does with the content and the end of an activity, without the Lock Screen: an end without a
/// relevance, the system's default dismissal, a dismissal at a time or in the past, and a reply that nobody awaits. It
/// leaves ended activities on the Lock Screen, so its UI test runs after the others.
// AK-BRIDGE-9, AK-END-2, AK-END-3, AK-END-6, AK-UPDATE-12
fn policies(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let events = kit.events();
    let status = |text: &str| values! { "status" => text };
    let mut checks = Checks {
        reporter,
        failed: Vec::new(),
    };

    let first = activitykit::Start::new(plain(), status("Fresh")).relevance(50.0);
    let activity = start_plain(&kit, first)?;

    // AK-BRIDGE-9: an update whose future is dropped; its reply still reaches the handle.
    let update = activity.update(status("Updated"));
    checks.check(
        block_on(poll_once(Box::pin(update))).is_none(),
        "the update waits for the main thread",
    );
    let replied = wait_until(Duration::from_secs(10), || {
        (activity.revision() == Some(1)).then_some(())
    });
    checks.check(
        replied.is_some(),
        "the reply of a dropped update reaches the handle",
    );

    // AK-UPDATE-12, AK-END-2: the system's default end without a relevance keeps the score and leaves the activity on
    // the Lock Screen.
    block_on(activity.end(End::default())).map_err(|error| format!("end: {error}"))?;
    checks.check(
        activity.state() == State::Ended && activity.relevance() == 50.0,
        format!(
            "the end keeps the score: {:?} {}",
            activity.state(),
            activity.relevance()
        ),
    );
    let kept = listed(&kit, &activity)?.map(|listed| (listed.state(), listed.relevance()));
    checks.check(
        kept == Some((State::Ended, 50.0)),
        format!("the list shows it ended with its score: {kept:?}"),
    );
    let dismissed = reaches(
        &kit,
        &events,
        &activity,
        State::Dismissed,
        Duration::from_secs(5),
    );
    checks.check(
        dismissed.is_none(),
        format!("a default end is not dismissed within 5 s ({dismissed:?})"),
    );

    // AK-END-6: an end with a relevance gives the final content that score.
    let scored = start_plain(
        &kit,
        activitykit::Start::new(plain(), status("Scored")).relevance(50.0),
    )?;
    block_on(scored.end(End::default().relevance(70.0)))
        .map_err(|error| format!("end: {error}"))?;
    let score = listed(&kit, &scored)?.map(|listed| listed.relevance());
    checks.check(
        score == Some(70.0),
        format!("the end's relevance reaches ActivityKit: {score:?}"),
    );

    // AK-END-3: dismissed at the time of `End::after`, not before.
    let at = SystemTime::now() + Duration::from_secs(8);
    let later = start_plain(&kit, activitykit::Start::new(plain(), status("Later")))?;
    block_on(later.end(End::after(at))).map_err(|error| format!("end: {error}"))?;
    let waiting = listed(&kit, &later)?.map(|listed| listed.state());
    checks.check(
        waiting == Some(State::Ended),
        format!("ended and still shown before its time: {waiting:?}"),
    );
    let gone = reaches(
        &kit,
        &events,
        &later,
        State::Dismissed,
        Duration::from_secs(60),
    );
    let early = at.duration_since(SystemTime::now()).unwrap_or_default();
    checks.check(
        gone.is_some() && early < Duration::from_secs(2),
        format!("dismissed at its time ({gone:?}, {early:?} early)"),
    );

    // AK-END-3: a time in the past.
    let past = start_plain(&kit, activitykit::Start::new(plain(), status("Past")))?;
    let asked = Instant::now();
    block_on(past.end(End::after(SystemTime::now() - Duration::from_secs(60))))
        .map_err(|error| format!("end: {error}"))?;
    let gone = reaches(
        &kit,
        &events,
        &past,
        State::Dismissed,
        Duration::from_secs(30),
    );
    checks.check(
        gone.is_some(),
        format!(
            "a past time dismisses it ({gone:?} after {:?})",
            asked.elapsed()
        ),
    );
    checks.outcome()
}

/// The receipt file of the Swift layer, as the app's Application Support holds it.
fn receipts_text() -> Result<String, String> {
    let home = std::env::var_os("HOME").ok_or("no HOME")?;
    let path = std::path::Path::new(&home)
        .join("Library/Application Support/activitykit/receipts-v2.json");
    std::fs::read_to_string(&path).map_err(|error| format!("{}: {error}", path.display()))
}

/// The start of the redacted scenarios; the same each time it is made.
fn secret_start() -> activitykit::Start {
    let first = values! { "status" => "First secret", "tone" => "green", "level" => 0.2 };
    activitykit::Start::new(layout(), first).key("host:redacted")
}

/// A kit whose receipts keep no values; other settings in the same process conflict.
// AK-KIT-3
fn redacted_kit(reporter: &Reporter) -> Result<ActivityKit, String> {
    let kit = ActivityKit::builder()
        .receipts(Receipts::Redacted)
        .build()
        .map_err(|error| format!("build: {error}"))?;
    check(
        matches!(ActivityKit::builder().build(), Err(Error::Conflict(_))),
        "other settings conflict with the first ones",
    )?;
    cleared(reporter, kit)
}

/// Starts and updates an activity with redacted receipts, then the UI test ends the process.
// AK-KIT-3, AK-LIST-4
fn redacted_start(reporter: &Reporter) -> Outcome {
    let kit = redacted_kit(reporter)?;
    let activity =
        block_on(kit.start_with(secret_start())).map_err(|error| format!("start: {error}"))?;
    block_on(
        activity.update(values! { "status" => "Second secret", "tone" => "red", "level" => 0.8 }),
    )
    .map_err(|error| format!("update: {error}"))?;
    starts_again(&kit, secret_start(), &activity)?;
    let text = receipts_text()?;
    check(
        !text.contains("First secret")
            && !text.contains("Second secret")
            && text.contains("digest"),
        "the receipt file keeps a digest and no values",
    )?;
    reporter.say(format!(
        "running {} with redacted receipts: terminate the app",
        activity.id()
    ));
    Ok(())
}

/// After a relaunch, the list gives the activity with the values ActivityKit shows; it continues and ends.
// AK-LIST-4, AK-START-3
fn redacted_check(reporter: &Reporter) -> Outcome {
    let kit = ActivityKit::builder()
        .receipts(Receipts::Redacted)
        .build()
        .map_err(|error| format!("build: {error}"))?;
    let activities = block_on(kit.activities()).map_err(|error| format!("activities: {error}"))?;
    let activity = activities
        .into_iter()
        .find(|activity| activity.key() == "host:redacted" && activity.state() == State::Active)
        .ok_or("no running activity with the key host:redacted")?;
    reporter.say(format!(
        "found {} at revision {:?} with {:?}",
        activity.id(),
        activity.revision(),
        activity.values().get("status")
    ));
    check(
        activity.revision() == Some(1)
            && activity.values().get("status") == Some(&Value::from("Second secret")),
        "the list gives the revision and the values that ActivityKit shows",
    )?;
    starts_again(&kit, secret_start(), &activity)?;
    block_on(
        activity.update(values! { "status" => "Third secret", "tone" => "green", "level" => 0.1 }),
    )
    .map_err(|error| format!("update: {error}"))?;
    check(
        activity.revision() == Some(2),
        "the handle continues the revision",
    )?;
    let text = receipts_text()?;
    check(
        !text.contains("secret"),
        "the receipt file still keeps no values",
    )?;
    block_on(activity.end(End::immediately())).map_err(|error| format!("end: {error}"))?;
    reporter.say(format!("updated to revision 2 and ended {}", activity.id()));
    Ok(())
}
