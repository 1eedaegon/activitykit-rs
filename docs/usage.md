# Usage

Everything goes through `ActivityKit`. It is `Clone + Send + Sync`, and on iOS every `ActivityKit::new()` shares one
Swift layer, so create it wherever it is handy, but create one early at launch: a button tap that launched the app
waits for it (see [Events](#events)).

```rust
use activitykit::ActivityKit;

let kit = ActivityKit::new();
let authorization = kit.authorization();
// supported: the device has Live Activities (iPhone with iOS 16.2, iPad with iPadOS 17).
// enabled: and they are on for this app. buttons: iOS 17 or later, where the OS runs a button's intent.
```

`authorization()` says what the device and the person allow. It does not check the app's setup: with `enabled` true a
start still answers `Error::ConfigurationRequired` when `NSSupportsLiveActivities` or the widget extension is missing,
and `buttons` does not check that the app links `ActivityKitIntent`.

Off iOS, `authorization()` reports nothing supported and every other call answers `Error::Unsupported` after it has
checked the request, so an invalid layout fails the same way on a Mac or Linux as on a phone.

The Swift layer has settings for the whole process, set once, before its first use:

```rust
use activitykit::{ActivityKit, Receipts};

let kit = ActivityKit::builder().receipts(Receipts::Redacted).build()?;
```

The first settings hold. A later `build` with other settings answers `Error::Conflict` and changes nothing; the same
settings again are fine, and `ActivityKit::new()` uses the settings in force. A start, update, end or list before any
`build` fixes the default settings, so build first. [After a relaunch](#after-a-relaunch) says what the receipts
keep. Off iOS `build` succeeds.

`kit.activity(id).await?` finds the handle of an activity by its id: the one alive in this process, without asking
ActivityKit, when it knows its revision, else the one the list gives, or `None` when ActivityKit does not list it.

## Layouts

A layout is a tree per region and a table of styles. The tree is fixed when the activity starts; values change it.

```rust
use activitykit::{Bound, Layout, Style};
use activitykit::layout::{button, hstack, progress, spacer, symbol, text, vstack, Font, Island};

let layout = Layout::new(vstack([
    hstack([symbol("mic.fill"), text(Bound::key("status")).style("status"), spacer(), button("stop", text("Stop"))]),
    progress("level").style("level"),
]).spacing(10.0))
.style("status", Style::new().font(Font::Headline).color(Bound::key("tone")))
.style("level", Style::new().tint(Bound::key("tone")))
.island(Island::new().compact_trailing(text(Bound::key("status"))));
```

| Builder | Node | Modifiers |
| --- | --- | --- |
| `vstack(children)`, `hstack(..)`, `zstack(..)` | 1 to 12 children | `spacing`, `alignment` |
| `spacer()`, `divider()` | | `min_length` (spacer) |
| `text("literal")`, `text(Bound::key("k"))` | text, literal or the value `k` | |
| `symbol("mic.fill")` | an SF Symbol | `rendering`, `variable(key)` |
| `image(ImageSource::asset(..))`, `image(ImageSource::file(..))` | an asset of the widget, or a PNG the app wrote | `resizable`, `content_mode` |
| `path(d, [w, h])` | SVG path data, without arcs | `stroke(width)` |
| `progress(key)`, `gauge(key)` | a number value | `kind`, `range` (gauge) |
| `timer(start, end)` | between two times in epoch milliseconds | `counts_up` |
| `button(action_id, label)` | a button; iOS 17 and later | |
| `link(url, label)` | a link that opens the app with a URL | |
| `custom(name)` | a SwiftUI view the app registers | `prop(key, value)` |

Every node takes `style(token)`, `when(key)` (drawn while the value is truthy), `unless(key)`,
`accessibility(..)`, `transition(..)` and `sensitive()`. A modifier that does not belong to a node leaves it as it is. Each builder returns a `Node`; the enum `Element` behind it is public
for anything the builders leave out.

Without an `Island`, the expanded island shows the Lock Screen tree, the compact leading and minimal parts the tree's
first symbol, and the compact trailing part nothing. `Layout::background` and `Layout::keyline` tint the Lock Screen
presentation and the island's keyline.

`Style::new()` has a builder for each member: `font`, `size`, `weight`, `design`, `font_family`, `monospaced_digit`,
`color`, `line_limit`, `minimum_scale_factor`, `alignment`, `padding`, `frame`, `background`, `corner_radius`,
`opacity`, `tint`, `button_style`, `content_transition`. Seven of them, and the layout's `background` and `keyline`, take
`Bound::key("value")` instead of a literal, so an update changes them: `color`, `background`, `tint` (a color name
or `#RRGGBB`/`#RRGGBBAA`), `size` (6 to 96), `opacity` (0 to 1), `corner_radius` (0 to 64) and `weight` (a weight
name). `font_family` names a font that the widget extension bundles and lists under `UIAppFonts`.

The [request contract](request-contract.md) has every rule and limit: at most 40 nodes on the Lock Screen, 8 levels,
4 buttons and links per region, 24 styles, 32 values, and layout, styles and values together within a weight of 3584.

### Motion and privacy

```rust
use activitykit::{Bound, Layout, Style};
use activitykit::layout::{text, vstack, ContentTransition, Transition};

let layout = Layout::new(vstack([
    // The digits roll when an update changes the value, and the system hides them on a locked device.
    text(Bound::key("total")).style("digits").sensitive(),
    // Comes in from below, pushing what was there away, when `paid` turns truthy.
    text("Paid").when("paid").transition(Transition::PushBottom),
]))
.style("digits", Style::new().monospaced_digit().content_transition(ContentTransition::NumericText));
```

`Style::content_transition` says how text and symbols change from one update to the next: `NumericText` (digits
roll upward), `NumericTextDown`, `Opacity`, `Interpolate` or `Identity` (at once). `Node::transition` says how a node
with `when` or `unless` comes and goes: `Opacity`, `Slide`, or `Move…` and `Push…` with an edge. These are the
animations the system runs in a Live Activity, for at most two seconds; it ignores any other. `Node::sensitive()`
marks what a node and its subtree show as private: the system hides it on a locked device and in the always-on
display when the person has asked for that.

### The Dynamic Island's options

```rust
use activitykit::layout::{symbol, text, timer, ExpandedRegion, Island, IslandExpanded, IslandMargins};

let island = Island::new()
    .expanded(IslandExpanded::new()
        .leading(symbol("mic.fill"))
        .trailing(timer("from", "to"))
        .priority(ExpandedRegion::Trailing, 1.0)            // the timer gets the width first
        .below_if_too_wide(ExpandedRegion::Leading))        // a wide leading region goes below the camera
    .compact_trailing(text(Bound::key("status")))
    .margins(IslandMargins::new().expanded(8.0).compact_trailing([0.0, 6.0, 0.0, 6.0]));
```

A priority is 0 to 100, for a region the layout has; only the leading and the trailing region go below the camera.
Margins are a number for every edge or `[top, leading, bottom, trailing]`, 0 to 64; a presentation without them keeps
the system's.

### Accessibility

```rust
use activitykit::Bound;
use activitykit::layout::{hstack, path, progress, symbol, text, Accessibility};

let row = hstack([
    // A drawing has no name of its own: give it one.
    path("M0 8 L8 0 L16 8", [16.0, 8.0]).accessibility(Accessibility::new().label("Rising")),
    // The value follows every update; a number is read as text shows it.
    progress("level").accessibility(Accessibility::new().label("Input level").value(Bound::key("percent"))),
    // Decoration says nothing.
    symbol("sparkles").accessibility(Accessibility::new().hidden()),
    text(Bound::key("status")),
])
// A stack with a label is one element: VoiceOver reads "Recorder" instead of each child.
.accessibility(Accessibility::new().label("Recorder").hint("Shows the recording"));
```

`label` says what a node is, `value` what it shows now and `hint` what acting on it does; each is text of 1 to 200
characters or `Bound::key(..)` to a value of any type. `hidden()` takes a node and its subtree away from assistive
technologies and stands alone. Without the member the system reads its own: the text of a `text`, the title of a
button, the name of an SF Symbol; a `path`, an `image` and a `custom` view have none. A bound member whose value is
empty is left out. Labels are part of the layout and count toward its weight: bind one when its text is a value
already.

### Links

```rust
use activitykit::{Bound, Layout};
use activitykit::layout::{hstack, link, text};

let layout = Layout::new(hstack([
    text(Bound::key("status")),
    // A tap on "Details" opens the app with this URL.
    link("myapp://recording/42/details", text("Details")),
]))
// A tap anywhere else on the activity, on the Lock Screen or in the Dynamic Island, opens the app with this one.
.url(Bound::key("target"));
```

A URL is 1 to 1024 ASCII characters with a scheme, such as `myapp://recording/42` or `https://example.com/r/42`;
percent-encode a space and anything outside ASCII. `Bound::key(..)` names a text value that is a URL, checked at the
start and on every update. A link stands where a button may (the Lock Screen and the expanded island, at most 4
buttons and links per region) and neither holds the other. Without `Layout::url` a tap opens the app without a URL.

The system opens the app that owns the activity and hands it the URL; the crate reports no event. The app takes it
where it takes every URL it is opened with: `onOpenURL` in SwiftUI, `application(_:open:options:)` or a scene's
`openURLContexts` in UIKit, or its framework's deep-link support. Check the URL there before acting on it: with
pushes, a server writes it.

## Values

```rust
use activitykit::{values, Values};

let values = values! { "status" => "Recording", "tone" => "green", "level" => 0.2, "live" => true };
let same = Values::new().with("status", "Recording").with("tone", "green").with("level", 0.2).with("live", true);
```

A value is text (up to 1000 characters), a number or a flag. An update sends every value again, with the same keys
and the same types as the start.

## Start, update, end

```rust
use activitykit::{Alert, End, Start, Update, values};
use std::time::{Duration, SystemTime};

let activity = kit
    .start_with(Start::new(layout, values! { "status" => "Recording", "tone" => "green", "level" => 0.2 }).relevance(50.0))
    .await?;

activity.update(values! { "status" => "Too loud", "tone" => "red", "level" => 0.8 }).await?;
activity
    .update_with(
        Update::new(values! { "status" => "Too loud", "tone" => "red", "level" => 0.9 })
            .alert(Alert::new("Too loud", "The level is high"))
            .stale_at(SystemTime::now() + Duration::from_secs(600)),
    )
    .await?;

activity.end(End::immediately().values(values! { "status" => "Stopped", "tone" => "gray", "level" => 1.0 })).await?;
```

- A start needs the app in the foreground (or a Live Activity intent of the app); otherwise ActivityKit refuses it and
  the start answers `Error::NotForeground`. Starts made right after the app leaves the foreground may still succeed:
  ActivityKit treats the app as visible for a short while after that. Each `start` is a new activity.
  `Start::key("rec")` gives it a key: while that activity runs, the same start returns it and a different one is
  `Error::Conflict`, within one launch and after a relaunch. The same start means the same layout, styles, values,
  stale date and revision; its timestamp and relevance do not count. `Start::revision` and `Start::timestamp` set the
  first content's revision (0 unless set) and timestamp (the time of the start unless set).
- Each update sends every value again; the handle adds the revision and a timestamp: the time it sends the content,
  unless `Update::timestamp` gives one. ActivityKit uses it on iOS 17.2 to drop older content: an update with a
  timestamp older than the shown content's still succeeds, and the handle and the list report its values, but the
  activity keeps showing the newer content. Clones of a handle, and every handle that `activities()` or an event gives
  for the same activity, share one count. If the activity already shows a newer revision, the update reads it and tries
  again only when its own content is the newer one; otherwise it answers `Error::StaleRevision`.
- Updates and ends of one activity go out one at a time, in the order their futures are first polled (a future does
  nothing until polled): a write waits for the answer of the one before it, and the handle takes that answer even when
  nobody awaits it. The Swift layer runs the calls of all activities one at a time as well, so a write that overtook
  one still in flight could end the activity with older values. Every call has the kit's call wait of 10 seconds: a
  call the Swift layer never answers fails with `Error::Native` then, a reply that comes later is discarded, and a
  write that waited in vain lets the next one go. A start that timed out may still have happened: `Event::Started`
  reports it, and a start with `Start::key` can be repeated safely. An `End` without values after a timed-out update
  ends with the values before that update. A write that fails keeps its revision taken, so the next one skips it; no
  revision is sent twice.
- `Update::revision(n)` and `End::revision(n)` send the revision you choose instead of the next one, and are not
  retried. The Swift layer takes a higher revision than the accepted one, answers the accepted one with the same
  values and stale date (whatever the timestamp) as done, and refuses a lower one with `Error::StaleRevision` and the
  accepted one with other content with `Error::Conflict`. Later writes without a revision continue above the highest
  revision sent.
- After an update with a timestamp older than the shown content's, which ActivityKit drops, the handle holds the
  dropped values, and an end without values ends with them under the time of the end, so ActivityKit shows them. Give
  that end its values.
- Relevance and stale date belong to each content, as in ActivityKit: an update or end without a relevance keeps its
  score, and one without a stale date clears the stale date. The highest score shows in the Dynamic Island.
- An alert lights up the screen and expands the Dynamic Island (without one, the Lock Screen presentation shows as a
  banner). Its title and body show only on an Apple Watch.
- An end carries final content: the values of `End::values`, else the last accepted ones (those of the updates called
  before it, which it waits for), with an optional stale date and relevance. `End::immediately()` removes the activity
  at once; `End::default()` keeps it on the Lock Screen for up to four hours, and `End::after(time)` until the time or
  four hours after the end, whichever comes first; a time in the past removes it at once. Times run to
  8 640 000 000 000 000 ms after 1970; a later one, like one before 1970, is `Error::InvalidInput`. Ending again is
  fine.
- `activity.state()`, `values()`, `revision()`, `timestamp()`, `stale_at()`, `relevance()` and `degraded_features()`
  give what the last reply or event said.

The system ends an activity after 8 hours and removes it from the Lock Screen after 12 hours. Dropping a handle,
every handle and the kit, or ending the process never ends the activity; dropping a future does not cancel its
request.

## After a relaunch

```rust
for activity in kit.activities().await? {
    // Pending, Active, Stale, Ended (still on screen) or Dismissed; the handle continues from the accepted revision.
}
```

The Swift layer keeps receipts of accepted requests in Application Support (`activitykit/receipts-v2.json`), because
ActivityKit can report an update late. By default a receipt holds the activity's key and its last accepted values in
plain text, in a file only the app's user can read, which iOS protects until the device is first unlocked after a
restart. With `Receipts::Redacted` it holds the key, the state, the accepted revision and a SHA-256 digest of the
content without its timestamp instead of the values; a digest of guessable values, such as a flag or a short word, can
be guessed. So can the start's fingerprint, a SHA-256 of the layout and the first values, which the receipt and
ActivityKit's attributes (`initialFingerprint`) keep in either mode; and ActivityKit itself keeps the values in the
activity's content. After a
relaunch the list then gives what ActivityKit shows: its values and its revision, which is older than the accepted
one only while ActivityKit lags behind an update. An ended activity that ActivityKit no longer lists is not listed in
either mode, and ending it again answers its record without values. Changes while the app was not running are not
replayed as events; the list gives the current state.

## Events

```rust
use activitykit::Event;

let events = kit.events();               // async_channel::Receiver<Event>, also a Stream
while let Ok(event) = events.recv().await {
    match event {
        Event::Started { activity, .. } => { /* an activity began, the app's or the system's */ }
        Event::Action { activity, action, acknowledgement, .. } => {
            /* a tap on button(action, ..): keep the event, or `acknowledgement`, while you act on it */
        }
        Event::State { activity, state, .. } => { /* Pending, Active, Stale, Ended, Dismissed, Unknown */ }
        Event::Authorization(authorization) => { /* turned on or off in Settings */ }
        _ => {}
    }
}
```

The enum and its variants leave room to grow, so match with `..` and a `_` arm. Each call of `events()` is a new
receiver that gets every later event, in the order the system reported them; events that came before the first
receiver wait for it, at most 16, and so do the events after every receiver was dropped. A receiver keeps every event
until it is read, without a limit, and a tap waits for every receiver: keep reading the receivers you create, or drop
them. Read with `recv().await` in an async runtime, `try_recv()` once per frame in a render or game loop, or
`recv_blocking()` on a worker thread.

A tap runs the button's App Intent in the app process, also when the app was not running: the system launches it in
the background. The intent posts the tap for at most 5 seconds, and the tap waits for at most 4 of them until every
receiver has handled it, which keeps such an app running meanwhile: until the receiver's event, and every clone of
it, is dropped, or `acknowledgement.acknowledge()` is called. An app that hands a tap to another thread, for example
to start recording, keeps the event or its acknowledgement until that thread is done; an app that drops the event as
soon as it reads it lets the intent return at once. Keep the event only while you act on it: taps reach the app one at
a time, so a held tap holds the later ones behind it, and a later tap's intent can give up after its 5 seconds before
the app has taken that tap, which then arrives late, when nothing may keep the app running. A tap for an activity that ActivityKit no longer
lists comes with a handle whose `key()` is empty and whose update answers `Error::NotFound`. A tap does not change the
activity; update it if the button should change.

## Pushes

A server can update an activity, end it, or start one, through APNs. The crate asks ActivityKit for what the
server needs, reports it, and builds the payloads; it holds no key and sends nothing.

```rust
use activitykit::{Push, Start, Event};

// A token of the activity's own (iOS 16.2): the server sends to /3/device/<token>.
let activity = kit.start_with(Start::new(layout.clone(), values.clone()).push(Push::Token)).await?;
// Or a broadcast channel the server made at APNs (iOS 18; UnsupportedFeature before).
let channel = activitykit::ChannelId::new("dHN0LXNyY2gtY2hubA==")?;
let shared = kit.start_with(Start::new(layout, values).push(Push::Channel(channel))).await?;

while let Ok(event) = events.recv().await {
    match event {
        Event::PushToken { activity, token, .. } => { /* send `token` (lowercase hex `Display`) to the server */ }
        Event::PushToStartToken { token, .. } => { /* the app's token for starts, with `push_to_start(true)` */ }
        Event::Updated { activity, .. } => { /* a push changed the content: `activity.values()` has it */ }
        _ => {}
    }
}
```

The token is not in the start's reply: ActivityKit makes it later, and may change it, and each one comes as
`Event::PushToken`. Push-to-start (iOS 17.2) needs
`ActivityKit::builder().push_to_start(true).build()`, a setting that holds for the process like the receipts; an
activity a push starts arrives as `Event::Started`, with its handle and the key the payload gave it, and a keyed
start of the app under that key answers `Error::Conflict`. Content a push delivers reaches the handle and
`Event::Updated` reports it, when its revision is above every revision the process sent or accepted for the
activity; the app's own updates, which ActivityKit reports the same way, do not arrive as `Event::Updated`. The kit
keeps what it learned of an activity while the process runs, handle or no handle, until the activity is dismissed;
what ActivityKit already showed when the kit began watching an activity is not reported, the list gives it. A
server should number its pushes above the app's revisions, which the app can tell it with `activity.revision()`. A
start that asks for a token needs the Push Notifications capability and APNs; without them ActivityKit refuses it,
and the start fails with `Error::ConfigurationRequired`, as it does in the simulator. `Authorization::frequent_pushes` says whether the person allows
frequent pushes, with `NSSupportsLiveActivitiesFrequentUpdates` in the app's Info.plist.

The payloads, from `activitykit::push`, on the server:

```rust
use activitykit::{Alert, push::{Payload, PRIORITY_NOW, PUSH_TYPE, topic}};

let update = Payload::update(values! { "status" => "Louder", "level" => 0.8 })
    .revision(3)                          // required: the revision the server sends next
    .alert(Alert::new("Louder", "The level rose"))
    .to_json()?;                          // {"aps": {"timestamp": …, "event": "update", "content-state": {…}, …}}
let end = Payload::end().dismiss_at(SystemTime::now() + Duration::from_secs(600)).to_json()?;
let start = Payload::start("la-ios-layout-s1", "job:1", layout, values! { "status" => "Started" })
    .alert(Alert::new("Started", "Tap to look"))    // required: the system shows the started activity with it
    .input_push_token()                            // iOS 18: the started activity gets a token of its own
    .to_json()?;
// Headers: apns-push-type: PUSH_TYPE, apns-topic: topic("dev.example.app"), apns-priority: PRIORITY_NOW
```

`to_json` checks a payload as the kit checks the call it stands for, and what APNs would refuse (more than 4096
bytes is `PayloadTooLarge`), so a bad one fails before APNs sees it. The `timestamp` of `aps` is the time of sending,
in seconds, by which the system orders pushes; the content's own `timestamp` and `staleAt` are in milliseconds, as in
every snapshot. A pushed alert plays no sound. A start payload carries the attributes the widget reads (`attributes-type`
`LiveActivityLayoutAttributes`): the id the handle will show, the key, the layout and the styles, and a fingerprint
of the server's own.

## Threads and executors

The async methods are plain futures; drive them with any executor. The Swift side runs each request on the main
thread and completes the future from there, so never block the main thread waiting for one, for example with
`block_on` in a frame callback or a UI event handler: that deadlocks. Calls are safe from any thread.

## Drawn images

```rust
kit.write_image("badge.png", &png_bytes)?;   // then show it with image(ImageSource::file("badge.png"))
```

The PNG goes to `activitykit/images` in the App Group container of the widget extension: give the app and the
extension the same App Group and name it under `ActivityKitAppGroup` in the extension's Info.plist. A PNG is at most
1 MiB and 1224 × 480 pixels. The widget reads it each time it draws, so write the new picture before the update.

## Custom views

A `custom("ring").prop("level", Bound::key("level"))` node draws a SwiftUI view that the app registers; see
`templates/ios/CustomViews.swift` and [iOS setup](ios-setup.md#custom-views). A name without a view draws nothing and
appears in `degraded_features()` as `layout.custom.ring`.

## Errors

`Error` has one variant per code of the contract: `Unsupported`, `InvalidInput`, `PayloadTooLarge`, `NotFound`,
`Conflict`, `StaleRevision`, `PermissionDenied`, `NotForeground`, `ConfigurationRequired` (no
`NSSupportsLiveActivities`, no widget extension with `ActivityKitLayout`, a missing entitlement, no App Group),
`UnsupportedFeature { feature, minimum_ios }`, `SystemLimit { scope }` (the app's or the device's limit) and `Native`.
`error.code()` gives the code as text. Messages are constant and never repeat a request. More variants may come.

## The contract

`activitykit::contract` holds the JSON requests and records and the validator that the Swift layer agrees with:
`validate_request("start_layout", json)`, `LayoutStartInput::validate_update` and `validate_end`, `weight`. Use it to
check requests that come as JSON, for example from a web view.

What ActivityKit offers and this crate does not support yet is in [Not yet supported](not-yet-supported.md).
