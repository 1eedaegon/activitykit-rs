//! Scenarios for a real iPhone (run.sh's DEVICE), which the simulator cannot run: a push that APNs delivers, and
//! StandBy. No UI test drives them: the app is launched with `-scenario`, and a person, or `examples/apns-sender`,
//! does the rest. docs/testing.md has the steps.

use super::{Outcome, Reporter, cleared, layout, next_event, prepared};
use activitykit::layout::{text, vstack};
use activitykit::{ActivityKit, Bound, Event, Layout, Push, Start, State, values};
use futures_lite::future::block_on;
use std::time::{Duration, Instant};

/// How long `apns` waits for the pushes of the sender.
const PUSHES_FOR: Duration = Duration::from_secs(900);

/// With the Push Notifications capability (run.sh's PUSH=1): starts an activity that asks for a push token, writes
/// the token to `Documents/apns-token.txt` for `examples/apns-sender`, and reports each content that a push brings,
/// until a push ends the activity or 15 minutes pass.
pub(crate) fn apns(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let events = kit.events();
    let start = Start::new(
        layout(),
        values! { "status" => "Waiting for a push", "tone" => "green", "level" => 0.1 },
    )
    .key("host:apns")
    .push(Push::Token);
    let activity = block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
    reporter.say(format!("started {}", activity.id()));
    let token = next_event(&events, Duration::from_secs(60), |event| match event {
        Event::PushToken { token, .. } => Some(token),
        _ => None,
    })
    .ok_or("ActivityKit gave no push token within 60 s")?;
    keep("apns-token.txt", &token.to_string())?;
    reporter.say(format!("token {token}"));
    let deadline = Instant::now() + PUSHES_FOR;
    while Instant::now() < deadline {
        let Some(event) = next_event(&events, Duration::from_secs(5), Some) else {
            continue;
        };
        match event {
            Event::Updated { activity, .. } => reporter.say(format!(
                "pushed revision {:?}, status {:?}",
                activity.revision(),
                activity.values().get("status")
            )),
            Event::State { state, .. } if matches!(state, State::Ended | State::Dismissed) => {
                reporter.say(format!("a push ended the activity: {state:?}"));
                return Ok(());
            }
            _ => {}
        }
    }
    Err("no push ended the activity within 15 minutes".into())
}

/// Writes `text` to `Documents/<name>` of the app, where devicectl copies it from.
fn keep(name: &str, text: &str) -> Outcome {
    let Some(home) = std::env::var_os("HOME") else {
        return Err("no HOME".into());
    };
    let path = std::path::Path::new(&home).join("Documents").join(name);
    std::fs::write(path, text).map_err(|error| format!("{name}: {error}"))
}

/// With the Push Notifications capability: a kit that watches the app's push-to-start token (iOS 17.2) writes it to
/// `Documents/apns-start-token.txt` for `examples/apns-sender start`, and reports the activity that a push starts,
/// within 15 minutes.
pub(crate) fn apns_start(reporter: &Reporter) -> Outcome {
    let built = ActivityKit::builder().push_to_start(true).build();
    let kit = cleared(reporter, built.map_err(|error| format!("build: {error}"))?)?;
    let events = kit.events();
    let asked = Instant::now();
    let token = next_event(&events, PUSHES_FOR, |event| match event {
        Event::PushToStartToken { token, .. } => Some(token),
        _ => None,
    })
    .ok_or("ActivityKit gave no push-to-start token within 15 minutes")?;
    reporter.say(format!(
        "the push-to-start token came {:?} after the kit",
        asked.elapsed()
    ));
    keep("apns-start-token.txt", &token.to_string())?;
    reporter.say(format!("push-to-start token {token}"));
    let started = next_event(&events, PUSHES_FOR, |event| match event {
        Event::Started { activity, .. } => Some(activity),
        _ => None,
    })
    .ok_or("no push started an activity within 15 minutes")?;
    reporter.say(format!(
        "a push started {} under the key {:?}, status {:?}",
        started.id(),
        started.key(),
        started.values().get("status")
    ));
    Ok(())
}

/// A line for the Lock Screen and one for StandBy, where a charging iPhone on its side shows the presentation full
/// screen: the person who puts the phone there says which line it shows.
pub(crate) fn standby(reporter: &Reporter) -> Outcome {
    let kit = prepared(reporter)?;
    let layout = Layout::new(vstack([
        text(Bound::key("status")),
        text("On the Lock Screen").unless_fullscreen(),
        text("In StandBy, full screen").when_fullscreen(),
    ]));
    let start = Start::new(layout, values! { "status" => "StandBy check" }).key("host:standby");
    let activity = block_on(kit.start_with(start)).map_err(|error| format!("start: {error}"))?;
    reporter.say(format!("started {}", activity.id()));
    Ok(())
}
