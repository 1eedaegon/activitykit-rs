# PRD: the iOS surface a cross-platform layer needs

Status: phases 1 and 2 are built and are in [the specification](spec.md) (AK-ACCESS-1 to 3, AK-LINK-1 to 5,
AK-MOTION-1 and 2, AK-PRIVACY-1, AK-ISLAND-1 and 2), except their simulator scenarios and the small region of
phase 2. Phase 3 is built (AK-START-13 and 14, AK-ALERT-1, AK-TOGGLE-1), each with a scenario on the simulator. Phase
4, a layout that follows staleness, is planned. Each requirement moves into the specification with its tests when it
is built, and leaves [Not yet supported](not-yet-supported.md).

## Why

`liveactivity-rs` puts one interface over this crate (iOS) and `liveupdate-rs` (Android), and framework plugins
(Tauri, Dioxus) sit on top of it. A review of that stack asked what the iOS engine must still offer before the common
layout can stand beside a native widget: accessibility, deep links, toggles, transitions, the Dynamic Island's own
options, the small region of Apple Watch and CarPlay, and the start options ActivityKit has and the crate does not.

Everything the widget draws needs the Swift renderer of this crate, so no layer above can add it. This document says
what this crate builds, in which order, what it deliberately leaves to the layers above, and how each part is proven.

## Who uses it

- An iOS app in Rust that uses `activitykit` directly.
- `liveactivity-rs`, which re-exports `Node`, `Element`, `Style`, `Bindable` and the validator.
- A server that builds push payloads with `activitykit::push::Payload` from the same layout.

Names say what a member means, not which SwiftUI call draws it: `url` and `link`, not `widgetURL`;
`accessibility.label`, not `accessibilityLabel`.

## Goals

1. A layout made of the contract's nodes is usable with VoiceOver without a custom view.
2. A tap can open the app at a place the layout names.
3. What ActivityKit offers for a Live Activity's presentation and start is reachable from the contract or the kit, each
   with the iOS version it needs and `UnsupportedFeature` below it.
4. Rust and Swift keep agreeing on every request to the byte: one rule, one fixture, both validators.

## Not goals

- CSS-like styling, free animation, or arbitrary SwiftUI: the `custom` node stays the way out.
- Anything Android: the projection, its options and its native styles belong to `liveactivity-rs` and `liveupdate-rs`.
- Delivering a tapped URL to Rust. The system hands it to the app like any URL (`onOpenURL`,
  `application(_:open:options:)`, a scene's `openURLContexts`); a framework's deep-link support takes it from there.
- An APNs client. The crate keeps building payloads and sending nothing.

## Already here: nothing to build

`liveactivity-rs` can use these today; where it does not, the change is on its side.

| Need | What 0.3 has | What the layer above lacks |
| --- | --- | --- |
| Relevance | `Start::relevance`, `Update::relevance`, `End::relevance`, `Activity::relevance()`, `relevance` in records | Its start, update and end specs carry no score |
| Alerts | `Update::alert(Alert::new(title, body))`, and the alert of a push payload | Its update input carries no alert |
| Lifecycle events | `Event::Started`, `Event::State`, `Event::Authorization` | Its adapter drops all three |
| A session that sends only the latest values | `Activity::revision()` follows pushes, `Event::Updated`, `Update::revision` | The session itself, which is its own design |
| Server payloads | `push::Payload` for start, update and end, `push::topic`, off iOS too | A transport, which is the server's |

## Requirements

Each row becomes requirements of the specification under the IDs named. "Proven by" lists the levels of
[testing.md](testing.md).

### Phase 1: accessibility and deep links

Render and contract only. The C functions, the lifecycle and the receipts do not change.

| ID | Requirement | Contract | Proven by |
| --- | --- | --- | --- |
| AK-ACCESS-1 | Any node carries what assistive technologies read: a label, a value, a hint, or that it is hidden. | `accessibility: { label?, value?, hint?, hidden? }` on every node | unit |
| AK-ACCESS-2 | The rules: at least one member; a literal is text of 1 to 200 code points; `label`, `value` and `hint` take a binding to a value of any type; `hidden: true` stands alone. | the same in Rust, Swift, schema and fixtures | unit, Swift host |
| AK-ACCESS-3 | The renderer reads literals as given and bound members as a `text` node shows the value; a missing or empty value leaves the member out. A node drawn as several views (a stack, a custom view) with a label, value or hint is one element that stands for what is inside. | — | Swift host; simulator |
| AK-LINK-1 | A layout names the URL a tap on the activity opens, and a `link` node the URL a tap on its child opens. | `layout.url`, `{ "type": "link", "url", "child" }` | unit |
| AK-LINK-2 | A URL is 1 to 1024 ASCII bytes: a scheme (`^[A-Za-z][A-Za-z0-9+.-]*:`), then at least one more character, all of them characters of RFC 3986 (letters, digits and ``-._~:/?#[]@!$&'()*+,;=``, and `%` before two hex digits). | the same everywhere | unit, Swift host |
| AK-LINK-3 | A link stands where a button may: on the Lock Screen and in the expanded regions, never inside a button or a link, with no button inside it; buttons and links together are at most 4 per region. | structural limit | unit, Swift host |
| AK-LINK-4 | Either URL may be bound to a text value, which must be a URL at start and on every update. | reference rule | unit, Swift host |
| AK-LINK-5 | The widget opens the app with the URL. A URL the system cannot parse draws the link's child without a link, and a layout URL like that is left out. The default of an absent island part looks through a link as through a button. | — | Swift host; simulator |

Decisions:

- **Additive in contract v2.** `schemaVersion` stays 2 and the members are optional, as `timestamp` and `push` came. A
  0.3 reader refuses a request with them, since input is strict; the Rust crate and its Swift layer ship together, so
  this only meets a server that pushes a newer layout to an older app. A server keeps to the members of the oldest app
  version it starts activities on.
- **One URL per layout**, not one per region: `DynamicIsland` takes one, and a region that needs another uses a link.
- **No scheme list.** Apple's documentation says that the system activates the containing app and passes it the URL
  (`onOpenURL`, `application(_:open:options:)`), for `widgetURL` and for `Link`, so the crate checks the form and the
  app decides what it follows. The documentation says nothing of schemes that are not the app's; on the simulator
  (iOS 26.3) a link with an `https` URL opened the test host with that URL, not a browser.
- **The label of a stack replaces its children's**, with the children combined, so that a button inside stays an
  action of the element. On the simulator the stack shows as one element with the button's trait, and a touch
  still reaches the button; what VoiceOver does when it activates that element is not tested.
- **The URL is opened as sent, or not at all.** From iOS 17 `URL(string:)` rewrites what it cannot read; the renderer
  asks for the strict reading, so the app never gets another URL than the layout's.

### Phase 2: presentation

Render and contract only. Built, except the small region.

| ID | Requirement | Contract | iOS |
| --- | --- | --- | --- |
| AK-MOTION-1 | Text and symbols change with the system's content transitions. | style member `contentTransition`: `numericText`, `numericTextDown`, `opacity`, `interpolate`, `identity` | 16.2 |
| AK-MOTION-2 | A node that appears or leaves with `if` or `unless` uses one of the transitions the system allows. | node member `transition`: `opacity`, `slide`, `moveTop` … `moveTrailing`, `pushTop` … `pushTrailing` | 16.2 |
| AK-ISLAND-1 | An expanded region states its priority and whether it may go below the camera when too wide. | `island.expanded.priority: { <region>: 0 to 100 }`, `island.expanded.belowIfTooWide: [leading, trailing]` | 16.2 |
| AK-ISLAND-2 | The island's presentations set their content margins. | `island.margins: { <presentation>: number or four edges }` | 16.2 |
| AK-PRIVACY-1 | A node is marked sensitive, and the system hides it on a locked device and in the always-on display. | node member `privacy: "sensitive"` | 16.2 |
| AK-SMALL-1 | A layout has a region of its own for Apple Watch and CarPlay; without it the system shows the compact views. Not built. | `layout.small: Node`, no buttons (proposed) | 18 (Watch), 26 (CarPlay) |

Decisions:

- **Flat words for a transition** (`moveTop`, not `{ "move": "top" }`): one enumeration in every layer and nothing
  to nest.
- **A child is known by its place in the layout.** The widget used to number the children it drew, so a child that
  came or went renumbered those after it and the wrong one animated. The place among all siblings, hidden ones
  counted, is stable.
- **A node is marked sensitive, never marked public.** The modifier is applied only where the layout asks, so that a
  child cannot undo what its stack says.
- **The small region waits.** A widget declares the families it draws once, for every activity, so a layout without a
  small region would lose the compact views the system shows on a watch today and get whatever the widget draws
  instead. That needs a default that looks right on a watch, and no test here can show a watch. It comes with a
  device to look at, not before.

General animation is not a goal: ActivityKit runs its own animation of at most two seconds and ignores the rest.

### Phase 3: interaction and start options

These reach the bridge, the lifecycle or the intents, so each has a scenario on the simulator. All four are built.

| ID | Requirement | Shape | iOS |
| --- | --- | --- | --- |
| AK-TOGGLE-1 | A toggle shows a flag and reports a tap as an action with the state asked for. | node `{ "type": "toggle", "actionId", "bind", "child" }`; `Event::Action` gains `on` | 17 |
| AK-START-13 | A start may be transient: the system ends the activity by itself. | `Start::transient()`, `"style": "transient"` beside the request | 18 |
| AK-START-14 | A start may be scheduled, with the alert the system requires; the activity is `Pending` until then and its key is taken. | `Start::scheduled(at, alert)`, `"scheduled"` beside the request | 26 |
| AK-ALERT-1 | An alert names its sound, in an update, a scheduled start and a push payload. | `Alert::sound(name)` | 16.2 |

`UnsupportedFeature { feature, minimum_ios }` answers each of these below its version, before ActivityKit is asked.

Decisions and findings:

- **Beside the request, not in it.** The style and the schedule are what ActivityKit takes for one call, like the
  relevance; the contract request and a keyed start's fingerprint stay as they are.
- **A pending activity holds its key and can be ended, and takes no update.** On the simulator (iOS 26.3) a start
  scheduled 15 s ahead was pending, was listed pending, and became active at its time; one ended while pending left
  the list. ActivityKit also took an update of the pending activity without an error, and then began it with the
  content of its start: the handle would have said one thing and the Lock Screen another. So an update answers
  `Conflict` until the activity began. A start scheduled a minute in the past was active at once.
- **What a transient activity does is the system's.** Apple describes it as shown in the expanded Dynamic Island and
  ended when the person locks the device, collapses that presentation or leaves the app. The simulator took the
  start, and still listed the activity active 25 s after the test host left the foreground; the crate promises the
  request, not the ending.
- **A toggle's tap asks, the app answers.** The intent of a toggle is the button's, with the state asked for: the
  opposite of the flag shown. Nothing changes until the app updates the value, so the switch never shows a state the
  app did not accept. On the simulator the switch was off, a tap reached Rust with `on: Some(true)`, the update turned
  it on, and the next tap asked for `false`.
- **A sound is a file name.** The same rule as an image's name, checked in Rust and in the bridge, so that it names
  nothing outside the folders the system reads sounds from.

### Phase 4: staleness

ActivityKit has a stale state: content with a stale date becomes stale when that date passes, the activity's state
is `stale`, and the widget is told so when it draws (`isStale`). The crate already sets the date (`stale_at`) and
reports the state (`State::Stale`); what is missing is a layout that looks different while its content is out of
date, without the app having to be running to send an update.

| ID | Requirement | Contract | iOS |
| --- | --- | --- | --- |
| AK-STALE-1 | A node is drawn only while the content is stale, or only while it is not. | node member `ifStale`: `true` or `false`; `Node::when_stale()`, `Node::unless_stale()` | 16.2 |

Decisions:

- **A member of its own, not a value.** Staleness is the system's, not the app's: it is no key of `values`, so `if`
  and `unless` keep meaning a value, and a node may carry both kinds of condition, which must both hold.
- **Only a condition.** A dimmed or relabelled variant is two nodes, one for each case; a style that changes with
  staleness can come later if two nodes prove clumsy.

Known limit: on the iOS 26.3 simulator ActivityKit reported no `stale` state for a stale date that had passed (the
specification says so). Whether the widget is redrawn as stale there is what the scenario of this phase finds out.

## Left to the layers above

- **Android's native presentation** (progress segments, metrics, chips, the Now Bar): a declarative Android member of
  the cross-platform request, resolved per snapshot.
- **Typed bindings**: a schema of value keys and types in TypeScript and Rust. If asked for, this crate can expose
  which keys a layout binds and what each must be; the rule exists privately in the validator.
- **A session with latest-wins updates**, and Dioxus or React adapters.
- **Push transport**: tokens, channels, retries and idempotency on the server.

### The request envelope

This crate's `LayoutStartInput` still carries `android` and `fallback`, which iOS checks and ignores, and its validator
refuses unknown members. So a cross-platform request that gains members of its own (`ios`, an Android presentation)
cannot be checked by handing its JSON to `validate_request`. The layer above reads its own request first and checks
the request it makes for this crate. Records already carry nothing of other platforms (0.2); the request follows when
contract v3 comes, not before: removing the two members now would break every 0.3 caller for no new behavior.

## Constraints

- **Strict input.** Unknown members, `null` and wrong types are `INVALID_INPUT`, nothing is corrected, and a request
  must read back as itself. Every new member needs its rule in Rust, Swift, the schema and the fixtures.
- **Payload weight.** Labels and URLs are part of the layout and count toward 3584 with the styles and the values. A
  label repeated for every row is paid for every row; bind it when the text is a value already.
- **Untrusted text.** With push-to-start a server writes the layout. A URL is checked for form only, and arrives in
  the app as any deep link does: the app validates it before acting on it.
- **Breaking for Rust callers.** `Node` gains a public member and `Element` a variant, so the release after phase 1 is
  0.4.0, and a match over `Element` needs an arm for `Link`.

## How it is proven

| Level | Runs | Covers |
| --- | --- | --- |
| unit | `cargo test` | builders, wire shapes, every rule and its limits, the fixtures |
| Swift host | `sh tests/swift/run.sh` | the Swift models and validator on the same fixtures, the renderer down to resolved nodes |
| simulator | `tests/ios-host/run.sh` | what SwiftUI and ActivityKit do with it: a label VoiceOver would read, a link that opens the app |
| build | `tests/build/run.sh` | the bridge for each iOS target |

Phase 1 is proven at the unit, Swift host and simulator levels: a scenario finds nodes by label and value on the
Lock Screen, touches a button inside a labelled stack, and follows a link, the layout's URL and an `https` link into
the test host. Phase 2 is proven at the unit and Swift host levels, and its SwiftUI is compiled and drawn by the
simulator's existing scenarios; what the system animates, hides and places has no scenario.

Known limits: a watch or CarPlay shows the small region only on real hardware or a paired simulator, a sound is not
heard by a test, and versions below the simulator's are read, not run.

## Rollout

| Release | Content | Docs |
| --- | --- | --- |
| 0.4.0 | Phase 1 | spec (AK-ACCESS, AK-LINK), request-contract, usage, ios-setup (receiving a URL), changelog |
| the next minor | Phase 2 without the small region | spec (AK-MOTION, AK-PRIVACY, AK-ISLAND), request-contract, usage |
| the minor after | Phase 3 | spec (AK-START-13 and 14, AK-ALERT-1, AK-TOGGLE-1), bridge, usage |
| later | The small region | with a watch to look at |

The version of a release follows its commits ([testing](testing.md#releases)); phases 1 and 2 are one release when
they reach `main` together.

## Open questions

1. (Settled) `Event::Action` of a toggle carries the state asked for, so an app need not keep what it last sent.
2. Does the small region need its own node limit, or the compact parts' 3? And what does a layout without one show
   on a watch once the widget declares the family?
3. Is a per-node `transition` enough, or does a layout need one default for all of its nodes?
