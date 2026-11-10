# Activitykit-rs

iOS Live Activities from Rust. You describe the activity in Rust; the crate's Swift layer, which it builds into your
Rust library, talks to ActivityKit, and a widget extension of a few lines draws it on the Lock Screen and in the
Dynamic Island. The crate is called `activitykit`.

## Install

```toml
[dependencies]
activitykit = "0.2"
```

Building for an iOS target compiles the Swift bridge into your Rust library, so it needs Xcode. On other targets the
crate builds without Swift and every call answers `Error::Unsupported`.

In Xcode ([details](docs/ios-setup.md)):

1. The app's Info.plist sets `NSSupportsLiveActivities` to `YES`.
2. The app target links the `ActivityKitIntent` product of this repository's `swift` package (for buttons) and
   compiles at least one Swift file, which can be its `main`.
3. A widget extension links the `ActivityKitWidget` product, sets `ActivityKitLayout` to the integer `2` in its
   Info.plist, and has this as its only Swift file:

```swift
import ActivityKitWidget
import SwiftUI
import WidgetKit

@main
struct Widgets: WidgetBundle {
    var body: some Widget { ActivityKitLayoutWidget() }
}
```

## Use

```rust
use activitykit::{ActivityKit, Bound, End, Event, Layout, Style, values};
use activitykit::layout::{button, hstack, progress, symbol, text, vstack};

let kit = ActivityKit::new();
// Whether the device and Settings allow activities; the app's own setup a start reports, as ConfigurationRequired.
if !kit.authorization().enabled {
    return Ok(());
}
let layout = Layout::new(vstack([
    hstack([symbol("mic.fill"), text("Recording").style("status"), button("stop", text("Stop"))]),
    progress("level"),
]))
.style("status", Style::new().color(Bound::key("tone")));

let activity = kit.start(layout, values! { "tone" => "green", "level" => 0.2 }).await?;
activity.update(values! { "tone" => "red", "level" => 0.8 }).await?;

let events = kit.events();
while let Ok(event) = events.recv().await {
    if let Event::Action { activity, action, .. } = event {
        if action == "stop" {
            activity.end(End::immediately().values(values! { "tone" => "gray", "level" => 1.0 })).await?;
        }
    }
}
```

The layout is fixed at start. An update sends every value again; the handle adds the revision and a timestamp, and
bound style members follow the values. `kit.activities().await` finds the activities again after a relaunch.
[Usage](docs/usage.md) has the rest: alerts, stale dates, relevance, every event, images and custom views.

The futures are plain futures for any executor. Events come through an async channel: `recv().await` in an async
runtime, `try_recv()` once per frame in a render or game loop, or `recv_blocking()` on a worker thread. Never block the
main thread on a future or a receiver: the Swift side answers from it.

## How it works

```text
Rust (ActivityKit, Activity) -> C bridge (8 functions, JSON) -> Swift (lifecycle, receipts) -> ActivityKit -> liveactivitiesd
Lock Screen, Dynamic Island  <- SpringBoard <- chronod <- your widget extension (ActivityKitLayoutWidget)
```

Rust checks each request against the contract, keeps the revision, and calls one of eight C functions with JSON
([the bridge](docs/bridge.md)). The Swift layer checks it again, runs it through the lifecycle (idempotent starts,
revisions, receipts of accepted updates) and calls ActivityKit, which hands the activity to the system's
`liveactivitiesd`. The system has your widget extension draw it through `chronod`: the widget reads the layout from the
activity's attributes and the values from its content state. A tap on a button runs an App Intent in your app's
process, which posts it to the bridge, and Rust delivers it as `Event::Action`.

## Limits

- iOS 16.2 or later on an iPhone, iPadOS 17 on an iPad. Buttons need iOS 17.
- An activity starts only while the app is in the foreground, or a short while after it left it. The system ends it
  after 8 hours and removes it from the Lock Screen after 12.
- The widget extension must be a Swift target in Xcode; a widget cannot be written in Rust.
- With Rust as a static library, the app target must compile some Swift, for the button's App Intents metadata and the
  bridge's Swift runtime.
- The Swift layer keeps each activity's last accepted values in plain text in the app's Application Support, which iOS
  protects until the first unlock after a restart, unless `ActivityKit::builder().receipts(Receipts::Redacted)` keeps
  a digest instead.
- No push updates, no Android. [Not yet supported](docs/not-yet-supported.md) lists what ActivityKit has and the crate
  does not.

[iOS setup](docs/ios-setup.md) · [Usage](docs/usage.md) · [Request contract](docs/request-contract.md) ·
[C bridge](docs/bridge.md) · [Specification](docs/spec.md) · [Testing](docs/testing.md) · [Changelog](CHANGELOG.md)

## License

[MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
