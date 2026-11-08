# Activitykit-rs

Live Activities for any Rust iOS app: Tauri, Dioxus, Bevy, Slint or your own. You describe the activity in Rust;
a small Swift layer, which this crate builds into your Rust library, talks to ActivityKit, and a widget extension
of a few lines draws it on the Lock Screen and in the Dynamic Island.

The crate is called `activitykit`. It is not on crates.io yet.

## Install

```toml
[dependencies]
activitykit = { git = "https://github.com/1eedaegon/activitykit-rs" }
```

Building for an iOS target compiles the Swift bridge into your Rust library; you need Xcode for that. On every other
target the crate builds without Swift, and each call answers `Error::Unsupported`.

Your Xcode project then needs three things ([details](docs/ios-setup.md)):

1. The app's Info.plist sets `NSSupportsLiveActivities` to `YES`.
2. A widget extension (a Swift target) linked to the `ActivityKitWidget` product of this repository's `swift`
   package, with `ActivityKitLayout` set to the integer `2` in its Info.plist, and this as its only Swift file:

   ```swift
   import ActivityKitWidget
   import SwiftUI
   import WidgetKit

   @main
   struct Widgets: WidgetBundle {
       var body: some Widget { ActivityKitLayoutWidget() }
   }
   ```

3. The app target links the `ActivityKitIntent` product (for buttons) and compiles at least one Swift file, which
   can be its `main`. Xcode then extracts the button's App Intents metadata and links the Swift runtime that the
   bridge's objects in your Rust static library need. (An app target without Swift needs
   `$(SDKROOT)/usr/lib/swift $(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)` in `LIBRARY_SEARCH_PATHS`, and gets
   no working buttons.) Build the Rust library with `IPHONEOS_DEPLOYMENT_TARGET` set to the app's target.

## Use

```rust
use activitykit::{ActivityKit, Bound, End, Event, Layout, Style, values};
use activitykit::layout::{button, hstack, progress, symbol, text, vstack};

let kit = ActivityKit::new();
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
    if let Event::Action { activity, action } = event {
        if action == "stop" {
            activity.end(End::immediately()).await?;
        }
    }
}
```

The futures run on any executor, and the events come through an `async-channel` receiver: `recv().await`, or
`try_recv()` in a game loop. The layout is fixed at start; an update sends every value again, and the handle keeps
the revision. [Usage](docs/usage.md) covers the layout nodes, styles, alerts, relaunches and threads.

[examples/dioxus](examples/dioxus) is a whole app, with an end-to-end test that taps the Stop button on the Lock
Screen of a simulator.

## Limits

- iOS 16.1 or later on an iPhone, iPadOS 17 on an iPad. Buttons need iOS 17.
- The widget extension must be a Swift target in Xcode; a widget cannot be written in Rust.
- With Rust as a static library, the app target must compile some Swift: for the button's App Intents metadata and
  for the Swift runtime of the bridge.
- An activity starts only while the app is in the foreground.
- No Android, no push updates yet.

## More

[iOS setup](docs/ios-setup.md) · [Usage](docs/usage.md) · [Request contract](docs/request-contract.md) ·
[C bridge](docs/bridge.md) · [Development](docs/development.md) · [Validation](docs/validation.md) ·
[Changelog](CHANGELOG.md)

## License

[MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
