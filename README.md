# Activitykit-rs

iOS Live Activities from Rust. You describe the activity in Rust; the crate's Swift layer, which it builds into your
Rust library, talks to ActivityKit, and a widget extension of a few lines draws it on the Lock Screen and in the
Dynamic Island. The crate is called `activitykit`.

## Install

```toml
[dependencies]
activitykit = "0.4"
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

## Features

Each row is one thing the crate does, the call that does it, and where the rest is written.

| Feature | Call | iOS | More |
| --- | --- | --- | --- |
| Is it allowed? | `kit.authorization()` → `supported`, `enabled`, `buttons`, `frequent_pushes` | 16.2 | [usage](docs/usage.md) |
| Start | `kit.start(layout, values)`, `kit.start_with(Start::new(..).key(..).relevance(..).stale_at(..))` | 16.2 | [start, update, end](docs/usage.md#start-update-end) |
| Update | `activity.update(values)`, `activity.update_with(Update::new(..).alert(..))` | 16.2 | [start, update, end](docs/usage.md#start-update-end) |
| End | `activity.end(End::immediately())`, `End::default()`, `End::after(time)`, `.values(..)` | 16.2 | [start, update, end](docs/usage.md#start-update-end) |
| Find again | `kit.activities()`, `kit.activity(id)` | 16.2 | [after a relaunch](docs/usage.md#after-a-relaunch) |
| Layout | `Layout::new(node)`, `vstack`, `hstack`, `zstack`, `text`, `symbol`, `image`, `path`, `progress`, `gauge`, `timer`, `spacer`, `divider` | 16.2 | [layouts](docs/usage.md#layouts) |
| Styles and bindings | `Style::new().color(..)`, `Bound::key("value")`, `node.when(key)`, `node.unless(key)` | 16.2 | [layouts](docs/usage.md#layouts) |
| Dynamic Island | `Layout::island(Island::new()..)`, `Layout::keyline(..)`, `Layout::background(..)` | 16.2 | [layouts](docs/usage.md#layouts) |
| Island priorities, placement, margins | `IslandExpanded::priority(..)`, `.below_if_too_wide(..)`, `Island::margins(..)` | 16.2 | [the island's options](docs/usage.md#the-dynamic-islands-options) |
| Motion | `Style::content_transition(..)`, `node.transition(..)` | 16.2 | [motion and privacy](docs/usage.md#motion-and-privacy) |
| Private content | `node.sensitive()` | 16.2 | [motion and privacy](docs/usage.md#motion-and-privacy) |
| Buttons and events | `button(action_id, label)`, `kit.events()` → `Event::Action` | 17 | [events](docs/usage.md#events) |
| Links | `link(url, label)`, `Layout::url(..)` | 16.2 | [links](docs/usage.md#links) |
| Accessibility | `node.accessibility(Accessibility::new().label(..))` | 16.2 | [accessibility](docs/usage.md#accessibility) |
| Images the app draws | `kit.write_image(name, &png)`, `image(ImageSource::file(name))` | 16.2 | [drawn images](docs/usage.md#drawn-images) |
| Your own SwiftUI | `custom(name).prop(key, value)` | 16.2 | [custom views](docs/usage.md#custom-views) |
| Pushes | `Start::push(Push::Token)`, `Event::PushToken`, `push::Payload` | 16.2; start 17.2; channels 18 | [pushes](docs/usage.md#pushes) |
| Receipts without values | `ActivityKit::builder().receipts(Receipts::Redacted).build()` | 16.2 | [after a relaunch](docs/usage.md#after-a-relaunch) |

### Describe what to draw

```rust
use activitykit::{Bound, Layout, Style};
use activitykit::layout::{hstack, progress, spacer, symbol, text, timer, vstack, Font, Island, IslandExpanded};

let layout = Layout::new(vstack([
    hstack([symbol("mic.fill"), text(Bound::key("status")).style("status"), spacer(), timer("from", "to")]),
    progress("level").style("level"),
    text("Too loud").when("loud"),                         // drawn only while the value `loud` is truthy
]).spacing(10.0))
.style("status", Style::new().font(Font::Headline).color(Bound::key("tone")))   // follows the value `tone`
.style("level", Style::new().tint(Bound::key("tone")))
.island(Island::new()
    .expanded(IslandExpanded::new().leading(symbol("mic.fill")).bottom(progress("level")))
    .compact_leading(symbol("mic.fill"))
    .compact_trailing(text(Bound::key("status")))
    .minimal(symbol("mic.fill")))
.keyline(Bound::key("tone"));
```

The tree is fixed when the activity starts. What changes is the values: bound text, bound style members, conditions,
progress, gauges and timers read them on every update.

### Start, update, end

```rust
use activitykit::{Alert, End, Start, Update, values};

let activity = kit.start_with(Start::new(layout, values! { "status" => "Recording", "tone" => "green", "level" => 0.2 })
    .key("recording")          // the same start again returns this activity instead of a second one
    .relevance(50.0)).await?;  // the highest score shows in the Dynamic Island

activity.update(values! { "status" => "Recording", "tone" => "green", "level" => 0.4 }).await?;
activity.update_with(Update::new(values! { "status" => "Too loud", "tone" => "red", "level" => 0.9 })
    .alert(Alert::new("Too loud", "The level is high"))).await?;   // lights the screen, expands the island

activity.end(End::default().values(values! { "status" => "Saved", "tone" => "gray", "level" => 1.0 })).await?;
```

An update sends every value again, with the keys and types of the start. `End::immediately()` removes the activity at
once, `End::default()` leaves it on the Lock Screen for up to four hours, `End::after(time)` until then.

### Buttons and events

```rust
use activitykit::Event;
use activitykit::layout::{button, text};

let stop = button("stop", text("Stop"));             // in the layout; iOS 17
let events = kit.events();
while let Ok(event) = events.recv().await {
    match event {
        Event::Action { activity, action, .. } if action == "stop" => activity.end(End::immediately()).await?,
        Event::State { activity, state, .. } => { /* Active, Stale, Ended, Dismissed */ }
        Event::Started { activity, .. } => { /* also one a push started */ }
        _ => {}
    }
}
```

A tap reaches the app even when it was not running: the system launches it, and the tap waits until the event is
dropped or acknowledged.

### Links

```rust
use activitykit::layout::{link, text};

let layout = Layout::new(link("myapp://recording/42/details", text("Details")))   // a tap on "Details"
    .url("myapp://recording/42");                                                 // a tap anywhere else
```

The system opens the app with the URL, and the app receives it where it receives every URL (`onOpenURL`, a scene's
`openURLContexts`, a framework's deep-link support). A URL may be `Bound::key(..)` to a text value.

### Accessibility

```rust
use activitykit::layout::{path, progress, symbol, Accessibility};

let trend = path("M0 8 L8 0 L16 8", [16.0, 8.0]).accessibility(Accessibility::new().label("Rising"));
let level = progress("level").accessibility(Accessibility::new().label("Input level").value(Bound::key("percent")));
let glitter = symbol("sparkles").accessibility(Accessibility::new().hidden());
```

VoiceOver reads the label, the value and the hint; a stack with one is read as a single element. Text, buttons and SF
Symbols have a name of their own; a path, an image and a custom view need one.

### Motion, privacy and the island's options

```rust
use activitykit::layout::{ContentTransition, ExpandedRegion, IslandMargins, Transition};

let total = text(Bound::key("total")).style("digits").sensitive();          // hidden on a locked device
let paid = text("Paid").when("paid").transition(Transition::PushBottom);    // how it comes and goes
let digits = Style::new().monospaced_digit().content_transition(ContentTransition::NumericText);   // digits roll
let island = Island::new()
    .expanded(IslandExpanded::new().leading(symbol("mic.fill")).trailing(timer("from", "to"))
        .priority(ExpandedRegion::Trailing, 1.0).below_if_too_wide(ExpandedRegion::Leading))
    .margins(IslandMargins::new().expanded(8.0));
```

### Images and your own views

```rust
use activitykit::layout::{custom, image, ImageSource};

kit.write_image("cover.png", &png_bytes)?;                        // at most 1 MiB and 1224 × 480, into the App Group
let cover = image(ImageSource::file("cover.png")).resizable();
let ring = custom("ring").prop("level", Bound::key("level"));     // a SwiftUI view the widget extension registers
```

### Pushes

```rust
use activitykit::{Alert, Push, push::{Payload, topic}};

// In the app: ask for a token, and send it to the server when it comes.
let activity = kit.start_with(Start::new(layout, values).push(Push::Token)).await?;
if let Ok(Event::PushToken { token, .. }) = events.recv().await { /* `token` displays as lowercase hex */ }

// On the server: the payload for APNs, checked like the update it stands for. The crate sends nothing.
let body = Payload::update(values! { "status" => "Louder", "tone" => "red", "level" => 0.8 })
    .revision(3)
    .alert(Alert::new("Louder", "The level rose"))
    .to_json()?;
let apns_topic = topic("dev.example.recorder");
```

### After a relaunch

```rust
for activity in kit.activities().await? {
    // The handle continues from the accepted revision: update or end it as before.
}
```

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
- A layout holds at most 40 nodes on the Lock Screen, 8 levels, 4 buttons and links per region, 24 styles and 32
  values, and layout, styles and values together weigh at most 3584 ([the contract](docs/request-contract.md)).
- An activity starts only while the app is in the foreground, or a short while after it left it. The system ends it
  after 8 hours and removes it from the Lock Screen after 12.
- The widget extension must be a Swift target in Xcode; a widget cannot be written in Rust.
- With Rust as a static library, the app target must compile some Swift, for the button's App Intents metadata and the
  bridge's Swift runtime.
- The Swift layer keeps each activity's last accepted values in plain text in the app's Application Support, which iOS
  protects until the first unlock after a restart, unless `ActivityKit::builder().receipts(Receipts::Redacted)` keeps
  a digest instead.
- Pushes: the crate asks for tokens and channels, reports them, builds payloads and takes what a push delivers; the
  APNs key, the tokens and the sending are the server's. No Android. [Not yet supported](docs/not-yet-supported.md)
  lists what ActivityKit has and the crate
  does not.

[iOS setup](docs/ios-setup.md) · [Usage](docs/usage.md) · [Request contract](docs/request-contract.md) ·
[C bridge](docs/bridge.md) · [Specification](docs/spec.md) · [Testing](docs/testing.md) ·
[Plan](docs/prd-ios-surface.md) · [Changelog](CHANGELOG.md)

## Releases

Releases follow the subjects of the commits on `main`: a `feat:` gives the next minor version, a `fix:`, `perf:`,
`refactor:`, `docs:` or `revert:` the next patch, and `test:`, `ci:`, `chore:`, `build:` and `style:` none. After CI
passed on `main`, a workflow bumps the version, writes the changelog, tags the commit and publishes to crates.io. A
major version is released only by running that workflow by hand ([testing](docs/testing.md#releases)).

## License

[MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
