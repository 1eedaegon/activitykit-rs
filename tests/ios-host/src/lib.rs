//! The scenarios of the iOS test host, in plain Rust: no UI framework, no async runtime. The host app (App/Host.swift)
//! calls `ak_host_run` once it is in the foreground; the scenario named by the launch arguments `-scenario <name>`
//! runs on a thread of its own, driving futures with `futures_lite::future::block_on`, which is fine off the main
//! thread. Every step is a line for the UI test, which reads the last one: `<step>`, then `PASS <scenario>` or
//! `FAIL <scenario>: <reason>`.

use activitykit::{
    Activity, ActivityKit, Bound, End, Error, Event, Layout, State, Style, Update, Value,
    layout::{
        ButtonStyle, Font, Frame, ImageSource, IndicatorKind, button, custom, divider, gauge,
        hstack, image, path, progress, spacer, symbol, text, timer, vstack, zstack,
    },
    values,
};
use futures_lite::future::block_on;
use std::{
    io::Write,
    thread,
    time::{Duration, Instant},
};

/// Set by the host app once it is in the background (App/Host.swift).
static IN_BACKGROUND: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// The host app calls this when it entered the background.
#[unsafe(no_mangle)]
pub extern "C" fn ak_host_entered_background() {
    IN_BACKGROUND.store(true, std::sync::atomic::Ordering::SeqCst);
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
        if scenario.is_empty() {
            reporter
                .say("idle: launch with -scenario lockscreen, relaunch-start or relaunch-check");
            return;
        }
        let outcome = match scenario.as_str() {
            "lockscreen" => lock_screen(&reporter),
            "relaunch-start" => relaunch_start(&reporter),
            "relaunch-check" => relaunch_check(&reporter),
            "background-start" => background_start(&reporter),
            "every-node" => every_node(&reporter),
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
    let kit = ActivityKit::new();
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

fn start(kit: &ActivityKit, reporter: &Reporter, key: &str) -> Result<Activity, String> {
    let first = values! { "status" => "Recording", "tone" => "green", "level" => 0.2 };
    let start = activitykit::Start::new(layout(), first)
        .key(key)
        .relevance(50.0);
    let activity = block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
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
// AK-AUTH-1, AK-CUSTOM-3, AK-END-1, AK-END-6, AK-EVENT-1, AK-EVENT-2, AK-EVENT-8, AK-HANDLE-3, AK-KIT-1, AK-START-1, AK-STATE-2, AK-THREAD-2, AK-UPDATE-1, AK-UPDATE-5, AK-UPDATE-11, AK-UPDATE-12
fn lock_screen(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let events = kit.events();
    let activity = start(&kit, reporter, "host:lockscreen")?;
    // AK-KIT-1: every kit of the process talks to the same Swift layer.
    let listed = block_on(ActivityKit::new().activities())
        .map_err(|error| format!("activities: {error}"))?;
    check(
        listed.contains(&activity),
        "a second kit lists the activity",
    )?;
    // AK-CUSTOM-3: the app registers no custom views, so the custom node is reported.
    check(
        activity.degraded_features() == ["layout.custom.ring"],
        format!("degraded features {:?}", activity.degraded_features()),
    )?;
    // AK-UPDATE-12: ActivityKit itself kept the score, read again a moment later.
    thread::sleep(Duration::from_secs(1));
    let relisted = block_on(kit.activities()).map_err(|error| format!("activities: {error}"))?;
    let shown = relisted
        .iter()
        .find(|listed| **listed == activity)
        .map(Activity::relevance);
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
            activity, action, ..
        } => Some((activity, action)),
        _ => None,
    });
    let (tapped, action) = tapped.ok_or("no tap within 3 minutes")?;
    reporter.say(format!("action {action} from {}", tapped.id()));
    check(
        action == "stop" && tapped == activity,
        "the tap names the button and the activity",
    )?;
    check(
        tapped.revision() == Some(1),
        "the tapped handle shares the started one's revision",
    )?;
    // AK-END-6: the end carries its final values.
    let last = End::immediately()
        .values(values! { "status" => "Stopped", "tone" => "gray", "level" => 1.0 });
    block_on(tapped.end(last)).map_err(|error| format!("end: {error}"))?;
    check(activity.state() == State::Ended, "the record of the end")?;
    check(
        activity.revision() == Some(2)
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

/// Start and update an activity, then the UI test ends the process.
fn relaunch_start(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let activity = start(&kit, reporter, "host:relaunch")?;
    reporter.say(format!(
        "running {} at revision 1: terminate the app",
        activity.id()
    ));
    Ok(())
}

/// After a relaunch, find the activity, continue its revision, and end it.
// AK-HANDLE-1, AK-LIST-1, AK-STATE-3
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

// AK-START-10
/// The UI test sends the app to the background before this starts: ActivityKit refuses, and the crate says why.
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
    thread::sleep(Duration::from_secs(1));
    let start = activitykit::Start::new(
        layout(),
        values! { "status" => "Late", "tone" => "green", "level" => 0.1 },
    );
    match block_on(kit.start_with(start)) {
        Err(Error::NotForeground(message)) => {
            reporter.say(format!("not in the foreground: {message}"));
            Ok(())
        }
        Err(error) => Err(format!("expected NotForeground, got {error}")),
        Ok(activity) => {
            let _ = block_on(activity.end(End::immediately()));
            Err("the start succeeded in the background".into())
        }
    }
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
