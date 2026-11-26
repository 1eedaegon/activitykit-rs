# Changelog

A release takes the subjects of its commits from `tools/release.sh`, above what was written by hand under
"Unreleased".

## Unreleased

- An app learns its push-to-start token. The Swift layer watched only the changes of the token
  (`pushToStartTokenUpdates`), and on an iPhone XS with iOS 18.7 none came in 5 minutes: the app already had a token,
  which did not change. It now reports the token the app has when the watch begins (`pushToStartToken`), then each
  new one, never the same one twice. Found on a phone; the simulator has no APNs.

## 0.9.0 - 2026-11-26

- feat: a node drawn only in StandBy, or only outside it (`b6069a0`)
- docs: what phones and a watch showed of 0.7.0 and 0.8.1 (`91211a1`)
- docs: the watch's Open on iPhone opens the app (`21f048c`)

- StandBy: `Node::when_fullscreen()` and `unless_fullscreen()` (the member `ifFullscreen`) draw a node only while the
  Lock Screen presentation fills the screen of an iPhone that charges on its side (iOS 17), or only while it does not.
  The widget reads `isActivityFullscreen`. A widget up to 0.8.1 passes over the member and draws the node always.

## 0.8.1 - 2026-11-20

- fix: the contract's types have constructors again outside the crate (`c842779`)

- The contract's requests and records, `#[non_exhaustive]` since 0.8.0, have constructors and builders, so a crate
  outside this one builds them without JSON: `LayoutRegions::new(lock_screen)` with `.island`, `.background`,
  `.keyline`, `.url` and `.small`; `LayoutSnapshot::new(revision, values)` with `.stale_at` and `.timestamp`;
  `LayoutStartInput::new(key, layout, snapshot)` (schema 2, fallback `none`) with `.styles`, `.fallback`, `.android`
  and `.push`; `AndroidOptions::new`, `LayoutUpdateInput::new(id, snapshot)`, `EndInput::new(id, policy)` with
  `.snapshot`; `EndPolicy::immediate()`, `EndPolicy::default()` and `EndPolicy::after(at)`;
  `LayoutActivityRecord::new(id, key, snapshot, state)` with `.degraded_features` and `.relevance`; and
  `Error::unsupported_feature(feature, (major, minor))` and `Error::system_limit(scope)`. The JSON is unchanged.

## 0.8.0 - 2026-11-20

- ci: a release run of an older commit ends without failing (`c4387a7`)
- feat: a widget draws an activity of a later crate or server (`1a57726`)
- feat: every public enum, variant and open struct leaves room for later (`96449a4`)
- style: rustfmt the timed end policy (`2a00230`)
- feat: Live Activities from iOS 16.1 (`3a91779`)

- A widget draws an activity of a later crate or a later server: it passes over the members of the layout, the styles
  and the content state that it does not know, and draws a node of a type it does not know as nothing, where it
  refused the whole layout and drew the activity empty. The app's requests stay strict, in Rust and in the bridge
  (`JSONDecoder.layoutRequests()`). A receipt that cannot be read costs that receipt and no longer fails every list
  with `NATIVE_ERROR`; a receipt of a later version, with members this one does not know, is read. A load keeps the
  newest 256 receipts.
- The crate runs Live Activities from iOS 16.1, ActivityKit's first release, where it answered `Unsupported` below
  16.2. On 16.1 the bridge starts, updates and ends an activity with ActivityKit's calls of that release, which take the
  content state alone: there is no stale date, no relevance score (a record has none, and the handle's is 0) and no
  frequent-pushes setting. The widget extension can be built for 16.1.
- Breaking, once, so that later releases are not: every public enum, every variant with named members and every public
  struct whose members are all public is `#[non_exhaustive]` (27 enums, 24 variants and 18 structs that were not). A
  `match` on such an enum needs a `_` arm and a pattern of such a variant `..`, as in `Error::UnsupportedFeature {
  feature, .. }`; such a struct or variant is built with its constructor or builder (`Layout::new`, `Style::new`,
  `Island::new`, `text(..)`, `ImageSource::asset(..)`, the new `Color::adaptive(light, dark)` and
  `ImageInput::new(name, png)`) or read from JSON, not with a literal. After that a new variant or member breaks no
  code.

## 0.7.0 - 2026-11-20

- perf: an update and a render do their fixed work once (`bce4362`)
- feat: the authorization says what the device runs (`753a2c5`)
- feat: a scheduled start is said only where the app can make one (`aae9950`)
- test: what assistive technologies read, and a system without ActivityKit (`d531968`)
- docs: what two phones showed of 0.6.6 (`1bfbbf5`)
- feat: a tap that the app does not take at once is kept (`6c4b791`)
- test: how much of a trailing value the expanded island shows (`bc1258a`)
- fix: the expanded island keeps a short trailing value whole (`7239bca`)
- docs: the expanded island's value shows whole on iOS 16.2 and 17.2 too (`f3490f3`)

- An update costs the Swift layer less. Its checks measured the activity's fixed attributes again each time, the
  weight of the layout and the size of the attributes encoded, which was most of their time: now each activity's
  are measured once, at its first update. On an Intel Mac the checks of an update of a layout of 40 nodes took
  616 µs before and 39 µs after. A widget's render resolves each style once, not once for each node that names it:
  a Lock Screen of 40 nodes rendered in 47 µs instead of about 100.
- `Authorization` says what the device runs of the features that came after the first Live Activities:
  `push_to_start` (iOS 17.2), `push_channels` and `transient` (18), `scheduled_start` (26), and `small_family` (18,
  with a widget extension that draws it). An app no longer has to try a request and read
  `Error::UnsupportedFeature` to learn it. A pattern on `Authorization` already needed `..`, so code that compiled
  goes on compiling.
- A tap that the app does not take at once is no longer lost. An app that the system launched for a tap had to make
  its kit within the 5 s for which the intent posts the tap, and a process that ended took its waiting taps with it.
  Now the intent keeps a tap that its first two posts (200 ms) do not get acknowledged in a small file in the app's
  container, and the first receiver of a later kit gets it, in this launch or the next, with `tap.late`.
  `Event::Action` has a `tap` member with the tap's `id`, its time and the revision of the content shown; a pattern on
  the variant already needed `..`. A tap for an activity that ActivityKit no longer lists comes with the key the
  button was drawn with, where its handle's `key()` was empty.
- The expanded Dynamic Island no longer cuts the last letter of a short trailing value: the widget keeps the leading and
  trailing regions 6 points from the top and from their outer side, on top of a layout's margins and padding.

## 0.6.6 - 2026-11-19

- ci: a release runs again the jobs that no runner took (`f38bbb9`)
- test: scenarios that show every kind of color in the small tile (`32df44f`)
- fix: the bridge builds with Xcode 27 (`35ede8c`)
- fix: buttons and toggles begin with iOS 17.2 (`6d94f0c`)
- fix: a control of a narrow layout is tapped on iOS 17 (`369723a`)
- test: where a layout's options put its nodes on the Lock Screen (`9ee3913`)
- docs: placement on the Lock Screen (`4b8bd88`)
- test: one flood reads a card, and the runner says what is missing (`8693ebc`)
- docs: where the placement was measured and what ran of the toggle (`6d6484f`)
- test: a box is the largest patch of its color in the card (`975facd`)
- test: a square box is known by its four corners (`972f258`)
- docs: the suite's runs on six systems (`27512fb`)

- The crate builds for iOS with Xcode 27. There `swift build` defaults to Swift Build, which does not build for iOS
  from the flags build.rs passes, and the build of the bridge failed; an app had to patch the crate. build.rs now
  names SwiftPM's own build system (`--build-system native`), the default up to Xcode 26. Reported from Xcode 27.2,
  which this repository's tests do not run on yet; on Xcode 26.3, Swift Build named by hand built the package for
  the Mac and left no library.
- Buttons and toggles begin with iOS 17.2, not 17.0. On iOS 17.0 a button was drawn and a tap on it ran nothing, in
  the app or in the widget (seen on the simulator; iOS 17.1 was not run). The cause is not the code but the metadata
  Xcode writes for it: an App Intent that is newer than the iOS its module is built for (this package: 15) is
  written as one that begins with iOS 17.2. Below 17.2 the widget now draws a button and a toggle as their labels,
  as it does on iOS 16, and `Authorization::buttons` is false.
- A button or a toggle in a layout that is narrower than the card can be tapped on iOS 17. There the system did not
  find a control of such content under a tap, took the tap as one on the activity and opened the app: on the
  simulators of iOS 17.2 and 17.4, for a text above a toggle or a button, and not for a layout that fills the card's
  width. The widget now takes the card's whole width for the content on the Lock Screen; a narrower layout stands in
  the middle of it as before. With it the same layouts were tapped on the simulators of iOS 17.2 and 17.4. iOS 18.0
  and 26.3 found such controls before the change.

## 0.6.5 - 2026-11-18

- fix: a color pair behind a card is drawn with the content (`4c47152`)
- fix: the widget draws a color pair in the small family too (`b5044b5`)
- docs: the Lock Screen was seen once with a light card and light content (`bc2963a`)

- A layout's `background` that is a light and dark pair is of the appearance its content is drawn in. The widget
  gave a pair to the system as the activity's background tint, and a card came with the pair's light color behind
  content of the dark appearance: white text on a light card. Seen on simulators with the iPhone in the light
  appearance, and on no phone or watch: on the Lock Screen of iOS 26.3 at some starts and not at others (here at one
  of two, in another project's pictures at 28 of 55), until the next update; and in the Smart Stack of a paired
  Apple Watch (watchOS 26.2), whose content is always dark. The widget now draws a pair itself, behind the content,
  in every activity family. A hex color and a color name are the system's tint as before. What changes with a pair:
  the system's own parts of a card, such as its question whether the app may go on showing Live Activities, have
  the system's colors and no longer the pair's.

## 0.6.4 - 2026-11-18

- fix: a button's tap asks for no state (`12ae8ec`)

- A button's tap comes without a state again: `Event::Action { on: None, .. }`. Since 0.5.0 it came with
  `on: Some(false)`, on a phone and on the simulator, so an app could not tell it from a toggle that was asked to
  switch off. The intent carried the state as one optional value, and the system hands the app a value that was
  never set as false. It now carries two, whether the tap is a toggle's and which state it asks for.
  `ActivityKitActionIntent.isOn` is a `Bool` beside the new `isToggle`; its initializer is unchanged.

## 0.6.3 - 2026-11-15

- test: a validator runs the schema against the fixtures (`fc734ce`)
- chore: no unwrap and no expect outside the tests, held by clippy (`5e10dfa`)
- refactor: nothing outside the tests can panic on an index or a panic (`eb8c17f`)

## 0.6.2 - 2026-11-14

- docs: the reply to an update of a stale activity differs between simulators (`4921190`)

## 0.6.1 - 2026-11-14

- docs: the Simulator's CarPlay display shows no Live Activity (`996db33`)

## 0.6.0 - 2026-11-14

- test: the schema names the members the valid fixtures carry (`be32e33`)
- chore: the plan's rollout names the releases that carried each phase (`828ac87`)
- feat: a small region for Apple Watch and CarPlay (`1b85938`)
- test: the preview takes its layout from the environment (`69f3919`)

The small family of Apple Watch and CarPlay, phase 5 of [the iOS surface plan](docs/prd-ios-surface.md).

- `Layout::small(node)` is what an activity shows in the Smart Stack of a paired Apple Watch (iOS 18) and in CarPlay
  (iOS 26): at most 12 nodes, without buttons, links or toggles. Request contract v2 gains `layout.small`.
- The widget draws the small family only when its extension's Info.plist sets `ActivityKitSmallFamily` to the Boolean
  true. A layout without a small region then shows its compact parts there, in a row. Without the key the system
  shows the compact parts itself, as before, and `degraded_features()` of an activity whose layout has the region
  holds `layout.small`. On iOS 18 the widget now states its supplemental families in either case, an empty list
  without the key.
- `LayoutContentView` draws an activity's content for the family in the environment; an app can use it to see a
  layout as a watch gets it.
- Breaking: `Layout` and `contract::LayoutRegions` have the public member `small`; in Swift, `LayoutRegion` has the
  case `small` and `LayoutRegions` the member `small`.

## 0.5.0 - 2026-11-13

- feat: scheduled and transient starts, and the sound of an alert (`fbc5c6b`)
- feat: a toggle node, and a pending activity that takes no update (`098cc94`)
- refactor: name the identifiers after io.github.1eedaegon.activitykit (`4d92b07`)
- feat: nodes that are drawn only while the content is stale, or fresh (`2706371`)
- docs: what the simulator said of the state after a stale activity's update (`319a75a`)

The start options and the alert sound of phase 3 of [the iOS surface plan](docs/prd-ios-surface.md).

- `Start::scheduled(at, alert)` starts an activity at a later time (iOS 26), with the alert the system shows then.
  Until `at` the handle is `State::Pending`; a pending activity holds its key and can be ended, and takes no
  update until it began (`Error::Conflict`).
- `Start::transient()` asks for a transient activity (iOS 18), which the system ends by itself.
- `Alert::sound(name)` names the sound of an alert, of an update, of a scheduled start and of a push payload.
- Below the iOS a start option needs, the start answers `Error::UnsupportedFeature` before ActivityKit is asked.
- The bridge's `ak_start` takes `style` and `scheduled` beside the request, and an alert a `sound`.

The toggle of phase 3.

- `toggle(action_id, key, label)` draws a switch that shows the flag `key` (iOS 17). A tap arrives as
  `Event::Action` with `on`, the state the person asked for; the app's update moves the switch. `on` is `None` for
  a button.
- Request contract v2 gains the node `toggle`; the bridge's `action` event may carry `on`, and the action intent a
  third parameter for it.
- Breaking: `Element` has the variant `Toggle`.

A layout that follows staleness, phase 4 of the plan.

- `Node::when_stale()` draws a node only while the content is stale, `Node::unless_stale()` only while it is not:
  the system says which when it draws the activity, so a layout changes after its stale date without an update and
  without the app running.
- Request contract v2 gains the node member `ifStale`; `LayoutView` and `LayoutDocument.render` take `isStale`.
- Breaking: `Node` has the public member `if_stale`.

Names.

- Breaking for a host that observes taps itself: the notification a tap is posted with
  (`ActionRelay.notification`, `ActionPost.notification`) is named `io.github.1eedaegon.activitykit.action`, after
  the project. Under its old literal name, `activitykit.action`, nothing arrives any more: read the constant
  instead. What the library stores keeps its paths.

## 0.4.0 - 2026-11-13

- docs: the plan for the iOS surface a cross-platform layer needs (`3725d26`)
- feat: accessibility members, links and a layout URL (`ee541d8`)
- docs: the README lists every feature with its call (`a487de0`)
- ci: releases follow the commit subjects (`1f76c27`)
- feat: transitions, sensitive nodes and the Dynamic Island's options (`19418c7`)
- test: labels and links on the Lock Screen, in the simulator suite (`d72a989`)

Phase 1 of [the iOS surface plan](docs/prd-ios-surface.md). Breaking for Rust callers: a new minor version, as
before 1.0.

- Accessibility. Every node takes `accessibility(Accessibility::new().label(..).value(..).hint(..))`, each member a
  text or `Bound::key(..)` to a value of any type, or `Accessibility::new().hidden()` for decoration. The widget
  gives them to VoiceOver; a stack with one becomes a single element that stands for its children.
- Links. `link(url, label)` opens the app with a URL when its label is tapped, and `Layout::url(..)` when the
  activity is tapped elsewhere, on the Lock Screen and in the Dynamic Island. A URL is 1 to 1024 ASCII characters
  with a scheme, or `Bound::key(..)` to a text value that is one. A link stands where a button may, and buttons and
  links together are at most 4 per region. The app receives the URL as any URL it is opened with; the crate reports no
  event.
- Request contract v2 gains three optional members: `accessibility` on a node, the node `link`, and `layout.url`.
  A 0.3 reader refuses a request that carries them; the crate and its Swift layer ship together.
- Breaking: `Node` has the public member `accessibility`, `Layout` and `contract::LayoutRegions` the member `url`, and
  `Element` the variant `Link`, so a struct literal needs the new member and a match over `Element` an arm for it.

Phase 2 of the plan, without the small region of Apple Watch and CarPlay.

- Motion. `Style::content_transition(..)` says how text and symbols change with an update (`NumericText` rolls the
  digits), and `Node::transition(..)` how a node with `when` or `unless` comes and goes: the transitions the system
  runs in a Live Activity. The widget now knows a child by its place in the layout, so the node that comes or goes is
  the one that animates.
- `Node::sensitive()` marks what a node shows as private; the system hides it on a locked device when asked to.
- The Dynamic Island's options: `IslandExpanded::priority(region, 0..=100)`, `IslandExpanded::below_if_too_wide(..)`
  for the leading and trailing regions, and `Island::margins(IslandMargins::new()..)` for each presentation.
- Request contract v2 gains the optional members `transition` and `privacy` on a node, `contentTransition` in a
  style, `priority` and `belowIfTooWide` in the expanded island and `margins` in the island.
- Breaking: `Node` has the public members `transition` and `privacy`, `Style` the member `content_transition`,
  `IslandExpanded` the members `priority` and `below_if_too_wide`, and `Island` the member `margins`.

## 0.3.0

- Pushes. `Start::push(Push::Token)` asks ActivityKit for a push token, which arrives as `Event::PushToken` with the
  handle; `Push::Channel(ChannelId)` subscribes the activity to a broadcast channel (iOS 18, `UnsupportedFeature`
  before). `ActivityKit::builder().push_to_start(true)` watches the app's push-to-start token (iOS 17.2), reported as
  `Event::PushToStartToken`. Content a push delivers reaches the handle and arrives as `Event::Updated` when its
  revision is above every revision the process sent or accepted; the app's own updates, which ActivityKit reports
  the same way, do not arrive as `Event::Updated`. The kit keeps what it learned of an activity until it is
  dismissed, handle or no handle. Without the Push Notifications capability and APNs, as in the simulator, a start that asks
  for a token fails with `Error::ConfigurationRequired`.
  `Authorization` gains `frequent_pushes`. `activitykit::push::Payload` builds the start, update and end payloads a
  server sends, checked like the calls they stand for, with `push::topic` and the header constants; the crate sends
  nothing.
- A tap that launches the app from not running is covered by the simulator suite: the app must make its kit within
  the intent's 5 s.
- The start request may carry `"push"` (`"token"` or `{"channel": "<id>"}`), `ak_configure` takes `pushToStart`, the
  authorization reply carries `frequentPushes`, and the bridge reports `pushToken`, `pushToStartToken` and `content`
  events. A 0.2 Swift layer and a 0.3 crate do not mix; they ship together.

## 0.2.0

- Breaking: a record carries what ActivityKit knows and nothing of other platforms. `contract::LayoutActivityRecord`
  loses `backend`, `visibility`, `promotion_requested` and `promotion_state`, the `Backend`, `Visibility` and
  `PromotionState` enums are gone, and the Swift record and the bridge's JSON no longer carry those members. A
  cross-platform layer adds its own at its boundary. `Activity` is unchanged. A 0.2 reader still reads a record written
  by 0.1; a 0.1 reader needs the members that 0.2 no longer writes.
- A call the Swift layer never answers fails with `Error::Native` after 10 seconds instead of waiting forever, and a
  reply that comes later is discarded. A write whose reply never comes frees the handle's turn, so the next write goes
  out at the next revision.

## 0.1.0

The first version: iOS Live Activities from Rust. Split out of tauri-plugin-live-activity 0.3.0.

- `ActivityKit`: `authorization`, `start` and `start_with` (key, stale date, relevance), `activities` after a relaunch,
  `events` (new activities, taps, lifecycle states with `Pending`, the whole authorization) through an `async-channel`
  receiver that is also a `Stream`, and `write_image`. Runtime-neutral futures; off iOS every call answers
  `Error::Unsupported`. iOS 16.2 or later.
- `Activity`: `update` and `update_with` (alert, stale date, relevance, timestamp) with the revision kept by the
  handle, `end` with final values, stale date, relevance and timestamp, and `state`, `values`, `revision`, `stale_at`,
  `relevance`. Writes of one activity go out one at a time, in the order their futures are first polled and without a
  timeout, so an end without values ends with the values of the updates before it; the handle takes a reply that
  nobody awaits. Timestamps are taken when the content is sent. An update or end without a relevance keeps the score;
  a retry after `STALE_REVISION` happens only for newer content.
- `ActivityKit::builder().receipts(Receipts::Redacted).build()`: settings of the Swift layer for the whole process,
  through a new C function, `ak_configure`; the first settings hold and others are `Error::Conflict`. Redacted
  receipts keep a digest instead of the values.
- `ActivityKit::activity(id)` finds a handle by its id; `Start::revision`, `Start::timestamp`, `Update::revision`,
  `End::revision` and `Activity::timestamp`.
- `Event::Action` carries an `Acknowledgement`: a tap's intent waits until every receiver has dropped its event or
  acknowledged it, so an app launched for the tap keeps running while it acts on it.
- A repeated keyed start, and the same revision sent again, count content without its timestamp: the same keyed start
  returns the running activity instead of `Error::Conflict`.
- `Error` with one variant per contract code, `NotForeground` for a start ActivityKit refuses outside the foreground,
  `UnsupportedFeature { feature, minimum_ios }` and `SystemLimit { scope }`.
- The layout DSL of request contract v2 with builders: nodes, styles, bound style members, `fontFamily`, drawn images
  and custom views. `activitykit::contract` holds the requests, the records and the validator.
- A Swift layer (validation, lifecycle, receipts, renderer) behind seven C functions; `build.rs` builds it into the
  Rust library for the device and both simulators. It holds layout activities only: the template activities of
  contract v1, and the migration of their receipts, are left out.
- Swift package products for Xcode: `ActivityKitWidget` (`ActivityKitLayoutWidget()`), `ActivityKitIntent` and
  `ActivityKitViews`.
- The contract schema and fixtures, now kept here. Request contract v2 gains an optional `timestamp` in snapshots,
  optional final content in `end_layout`, `relevance` in records and the state `pending`; an `after` end takes any
  time.
- `docs/spec.md`, every requirement mapped to its tests, checked by `tools/spec-coverage.sh`.
- An iOS test host under `tests/ios-host`: plain Rust scenarios and UI tests on a simulator (the Lock Screen button,
  every node type, a start from the background, a relaunch, ActivityKit's stale dates, dismissals and relevance), run
  by one script locally and in CI.
- CI on Linux and macOS (the macOS job for any change that reaches the Swift layer), a job on the minimum Rust, 1.90,
  and a publish workflow that only validates until crates.io publishing is turned on.
