//! A Dioxus app with a Live Activity: a recording status whose color is bound to a value, a level bar, and a Stop
//! button on the Lock Screen whose tap reaches Rust as an event.
//!
//! Launched with `-auto` (as the end-to-end test does) it runs the whole flow by itself: start, update after two
//! seconds (the status turns red), then end once Stop is tapped. Every step is logged to stdout, to the page and to
//! `Documents/activitykit-example.log` in the app's container.

use activitykit::{
    Activity, ActivityKit, Bound, End, Event, Layout, Style, Update,
    layout::{
        ButtonStyle, Font, FontWeight, Island, IslandExpanded, button, hstack, progress, spacer,
        symbol, text, vstack,
    },
    values,
};
use dioxus::prelude::*;
use std::{io::Write, time::Duration};

/// The app's entry point, which `ios/App/main.m` calls. It does not return.
#[unsafe(no_mangle)]
pub extern "C" fn start_app() {
    dioxus::launch(app);
}

fn layout() -> Layout {
    let status = hstack([
        symbol("mic.fill").style("status"),
        text(Bound::key("status")).style("status"),
        spacer(),
        button("stop", text("Stop")).style("stop"),
    ])
    .spacing(8.0);
    Layout::new(vstack([status, progress("level").style("level")]).spacing(10.0))
        .style(
            "status",
            Style::new()
                .font(Font::Headline)
                .weight(FontWeight::Semibold)
                .color(Bound::key("tone")),
        )
        .style("level", Style::new().tint(Bound::key("tone")))
        .style(
            "stop",
            Style::new()
                .button_style(ButtonStyle::BorderedProminent)
                .tint(Bound::key("tone")),
        )
        .island(
            Island::new()
                .compact_leading(symbol("mic.fill").style("status"))
                .compact_trailing(text(Bound::key("status")).style("status"))
                .expanded(IslandExpanded::new().bottom(vstack([
                    text(Bound::key("status")).style("status"),
                    progress("level").style("level"),
                ]))),
        )
}

/// A future that is ready after `duration`, from a thread of its own: the app needs no async runtime for it.
async fn sleep(duration: Duration) {
    let (done, wait) = activitykit::async_channel::bounded::<()>(1);
    std::thread::spawn(move || {
        std::thread::sleep(duration);
        let _ = done.try_send(());
    });
    let _ = wait.recv().await;
}

/// Appends a line to stdout, the page and the log file.
fn note(mut lines: Signal<Vec<String>>, line: String) {
    println!("[activitykit-example] {line}");
    if let Some(home) = std::env::var_os("HOME") {
        let path = std::path::Path::new(&home).join("Documents/activitykit-example.log");
        if let Ok(mut file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
        {
            let _ = writeln!(file, "{line}");
        }
    }
    lines.write().push(line);
}

fn app() -> Element {
    let kit = use_hook(ActivityKit::new);
    let lines = use_signal(Vec::<String>::new);
    let mut status = use_signal(|| String::from("idle"));
    let mut current = use_signal(|| None::<Activity>);
    let auto = use_hook(|| std::env::args().any(|argument| argument == "-auto"));

    // Every event of the kit, for as long as the app runs.
    let events = kit.clone();
    use_future(move || {
        let events = events.events();
        async move {
            while let Ok(event) = events.recv().await {
                match event {
                    Event::Action { activity, action } => {
                        note(lines, format!("action {action} from {}", activity.id()));
                        if action == "stop" {
                            match activity.end(End::immediately()).await {
                                Ok(()) => {
                                    note(lines, format!("ended {}", activity.id()));
                                    status.set("ended".into());
                                }
                                Err(error) => note(lines, format!("end failed: {error}")),
                            }
                        }
                    }
                    Event::State { activity, state } => {
                        note(lines, format!("state of {}: {state:?}", activity.id()))
                    }
                    Event::Authorization { enabled } => {
                        note(lines, format!("authorization: enabled={enabled}"))
                    }
                    _ => {}
                }
            }
        }
    });

    let start_kit = kit.clone();
    let start = move || {
        let kit = start_kit.clone();
        async move {
            let authorization = kit.authorization();
            note(lines, format!("authorization: {authorization:?}"));
            if !authorization.enabled {
                status.set("Live Activities are off".into());
                return;
            }
            let values = values! { "status" => "Recording", "tone" => "green", "level" => 0.2 };
            match kit.start(layout(), values).await {
                Ok(activity) => {
                    note(
                        lines,
                        format!(
                            "started {} (key {}, revision {:?})",
                            activity.id(),
                            activity.key(),
                            activity.revision()
                        ),
                    );
                    current.set(Some(activity));
                    status.set("started".into());
                }
                Err(error) => {
                    note(lines, format!("start failed: {error}"));
                    status.set("failed".into());
                }
            }
        }
    };
    let update = move || async move {
        let Some(activity) = current() else { return };
        let values = values! { "status" => "Too loud", "tone" => "red", "level" => 0.8 };
        match activity.update_with(Update::new(values)).await {
            Ok(()) => {
                note(
                    lines,
                    format!(
                        "updated {} to revision {:?}: tone red",
                        activity.id(),
                        activity.revision()
                    ),
                );
                status.set("updated".into());
            }
            Err(error) => note(lines, format!("update failed: {error}")),
        }
    };
    let end = move || async move {
        let Some(activity) = current() else { return };
        match activity.end(End::immediately()).await {
            Ok(()) => {
                note(lines, format!("ended {}", activity.id()));
                status.set("ended".into());
            }
            Err(error) => note(lines, format!("end failed: {error}")),
        }
    };

    let mut started_auto = use_signal(|| false);
    let auto_start = start.clone();
    use_future(move || {
        let start = auto_start.clone();
        async move {
            if !auto || started_auto() {
                return;
            }
            started_auto.set(true);
            note(lines, "auto: start, update in 2 s, end on Stop".into());
            start().await;
            sleep(Duration::from_secs(2)).await;
            update().await;
        }
    });

    let manual_start = start.clone();
    rsx! {
        div { style: "font-family: -apple-system, sans-serif; padding: 56px 20px 20px; color: #1c1c1e;",
            h2 { style: "margin: 0 0 4px;", "activitykit + Dioxus" }
            p { id: "status", style: "margin: 0 0 16px; font-weight: 600;", "Status: {status}" }
            div { style: "display: flex; gap: 8px; margin-bottom: 16px;",
                button { onclick: move |_| { let start = manual_start.clone(); spawn(async move { start().await; }); }, "Start" }
                button { onclick: move |_| { spawn(async move { update().await; }); }, "Update" }
                button { onclick: move |_| { spawn(async move { end().await; }); }, "End" }
            }
            ol { style: "font: 13px ui-monospace, monospace; padding-left: 20px;",
                for (index, line) in lines().iter().enumerate() {
                    li { key: "{index}", "{line}" }
                }
            }
        }
    }
}
