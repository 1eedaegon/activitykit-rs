# Feature specification

What `activitykit` promises, one requirement per row. Each ID is named by the tests that prove it, and
`tools/spec-coverage.sh` fails when a requirement has no test, a listed test does not exist or does not name it, or a
test names an ID this file lacks. Levels: **unit** (Rust, `cargo test`, with a fake bridge), **doc** (a doctest of
the rustdoc), **Swift host** (`tests/swift/run.sh` on the Mac), **simulator** (`tests/ios-host/run.sh`) and **build**
(`tests/build/run.sh`).
Errors are variants of `activitykit::Error`. iOS versions are where ActivityKit has the feature.

## Kit and authorization

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-KIT-1 | `ActivityKit::new()` reaches the process's one Swift layer: clones and every further `new()` share it. The type is `Clone + Send + Sync`. | A second kit lists an activity that the first one started. | — | iOS 16.2+ |
| AK-KIT-2 | Off iOS every call checks its request, then answers `Unsupported`; `authorization()` reports nothing supported and `events()` never yields. | A valid start → `Unsupported`; an invalid one → `InvalidInput`. | `Unsupported`, `InvalidInput` | off iOS |
| AK-KIT-3 | `ActivityKit::builder().receipts(..).build()` sets the Swift layer's settings for the whole process. The first settings hold: a later `build` with other settings fails and changes nothing, the same settings again succeed. A start, update, end or list before any `build` fixes the default settings (full receipts). Off iOS `build` succeeds and every call stays `Unsupported`. | `build` redacted, then `build` full → error; redacted again → the kit. | `Conflict` | all |
| AK-KIT-4 | `activity(id)` gives the handle of the activity `id`: the one alive in this process when it knows its revision, without asking ActivityKit, else the one the list gives; `None` when ActivityKit does not list it. | A started id → its handle, no list; an id only a tap named → listed; an unknown id → `None`. | `Unsupported` off iOS | all |
| AK-AUTH-1 | `authorization()` answers at once, from any thread: `supported` (the device has Live Activities), `enabled` (and they are on for the app), `buttons` (iOS 17, where the OS runs a button's intent). | An iPhone 17 Pro simulator with iOS 26 → all three true. | — | iOS 16.2+; `buttons` iOS 17+ |
| AK-AUTH-2 | With Live Activities off in Settings, `enabled` is false and a start fails. | Turned off → `enabled: false`; start → error. | `PermissionDenied` | iOS |
| AK-AUTH-3 | A change of that setting arrives as `Event::Authorization(Authorization)`, the whole authorization after the change. | Turned off → `Authorization { enabled: false, .. }` to every receiver. | — | iOS 16.2+ |
| AK-AUTH-5 | The observer of that setting holds its `ActivityAuthorizationInfo` for as long as it watches. | A source that only the watcher holds keeps reporting. | — | iOS 16.2+ |
| AK-AUTH-4 | An answer of the Swift layer that cannot be read counts as nothing supported. | A malformed answer → all false. | — | all |
| AK-AUTH-6 | `authorization()` does not check the app's setup: with `enabled` true a start can still fail for a missing `NSSupportsLiveActivities` or widget extension, and `buttons` does not check that the app links `ActivityKitIntent`. | Enabled, no widget extension → the start fails. | `ConfigurationRequired` | all |
| AK-AUTH-7 | `Authorization` leaves room for more members: a pattern needs `..`. | A pattern without `..` does not compile. | — | all |

## Start

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-START-1 | `start(layout, values)` sends a request of contract v2 (schema 2, revision 0, fallback `none`) and returns a handle at revision 0, state `Active`, with its values. | The README's layout with `tone` green → that request, a handle `la-ios-layout-…`. | see AK-START-5 to AK-START-9 | iOS 16.2+, app in the foreground |
| AK-START-2 | Without `Start::key` each start gets a key of its own, so each start is a new activity. | Two starts → two handles, two keys. | — | all |
| AK-START-3 | With `Start::key`, while that activity runs, the same start returns it and another start under the key fails; after it ends, the key starts a new activity. The same start is the same layout, styles, values, stale date and revision: the timestamp, taken anew for each start, and the relevance do not count. This holds within one launch and after a relaunch. | Same start twice, 1 ms apart → one handle; other values → error; after the end → a new handle; after a relaunch → the running handle. | `Conflict` | iOS |
| AK-START-4 | `Start::stale_at` and `Start::relevance` reach the request and ActivityKit. | `stale_at(t)` → `staleAt` in epoch ms; `relevance(50)` → ActivityKit gets 50. | `InvalidInput` (a time before 1970, a score that is not finite) | iOS 16.2+ |
| AK-START-5 | A layout or values that break the contract fail before anything reaches Swift. | A node names a missing style → error, no request. | `InvalidInput` | all |
| AK-START-6 | Layout, styles and values weigh at most 3584 together; Swift also checks ActivityKit's 4 KB on the encoded payload. | Four values of 1000 characters → error before sending. | `PayloadTooLarge` | all |
| AK-START-7 | Where Live Activities are unsupported, a start fails. | Off iOS, an iPhone below 16.2, an iPad below 17, an iOS app on a Mac → error. | `Unsupported` | all |
| AK-START-8 | A refusal of the system keeps its code: each `ActivityAuthorizationError` case maps to one code, and the message names the case. | `denied` → `PermissionDenied`; `targetMaximumExceeded` → `SystemLimit { scope: App }`; `unsupported` → `Unsupported`; `unsupportedTarget` and `unentitled` → `ConfigurationRequired`. | `PermissionDenied`, `SystemLimit`, `PayloadTooLarge`, `Unsupported`, `ConfigurationRequired`, `NotForeground`, `Native` | iOS |
| AK-START-9 | A start needs the app's setup: `NSSupportsLiveActivities` and an embedded widget extension with `ActivityKitLayout` = 2. | No such extension → error. | `ConfigurationRequired` | iOS |
| AK-START-12 | `Start::revision` and `Start::timestamp` set the first content's revision and timestamp; by default 0 and the time the start is sent. | `revision(5)` → the handle at 5, the next update sends 6. | `InvalidInput` (above the largest revision or time) | all |
| AK-START-10 | The crate checks no app state before a start: ActivityKit decides, and its `visibility` refusal is `NotForeground`. | A start while the app is in the background → error. | `NotForeground` | iOS 16.2+ |
| AK-START-11 | Starts made right after the app leaves the foreground may still succeed: ActivityKit treats the app as visible for a short while after that, and refuses later starts with `visibility`. Seen: CI's iOS 26.2 simulator (arm64) took a start right after the background signal; on iOS 26.3 (x86_64) the first start was refused in 5 runs of 5, under 4 ms after the signal. The test host tries every second for up to 20 s, ends each activity that still started, and passes at the first refusal. | Starts every second after the background signal → `NotForeground` within 20 s. | `NotForeground` | iOS 16.2+ |

## Update

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-UPDATE-1 | `update(values)` sends every value with the handle's next revision; the handle then reports that revision and those values. | At revision 0 → sends 1; `revision()` = 1. | see AK-UPDATE-6, AK-UPDATE-7 | iOS 16.2+ |
| AK-UPDATE-2 | `Update` options reach the request and ActivityKit: an alert, a stale date, a relevance; an update without options has none. | `alert(Alert::new("Loud", …))` → ActivityKit gets that alert. | `InvalidInput` (a time before 1970, a score that is not finite) | iOS 16.2+ for stale date and relevance |
| AK-UPDATE-3 | Clones, listed handles and event handles of one activity share one revision count. Its updates and ends go out one at a time, in the order their futures are first polled (not the order they were made): each waits until the one before has its answer (AK-UPDATE-17), also when that one's future was dropped, so no revision is sent twice and an end sees the values before it. | Two concurrent updates and four threads → revisions 1 to 6; an update and an end at once → the end carries the update's values; a future made first and polled second → the second revision. | — | all |
| AK-UPDATE-4 | When the activity already shows a newer revision, an update or end reads the list and tries once more only if its own content is newer: the shown content has an older timestamp or none (an equal one is not older); other errors are not retried, and a second failure is the answer. | At 5 with older content → sends 1, then 6; at 9 with newer content or the same timestamp → `StaleRevision`, no retry. | `StaleRevision`; `Conflict` | iOS |
| AK-UPDATE-5 | Bound text and bound style members show the values of the latest update. | `tone` green → red: symbol, status, Stop button and level bar turn red. | — | iOS 16.2+ |
| AK-UPDATE-6 | An update keeps the keys and value types of the start, and each value fits what it is bound to. | A number where text was, or `crimson` for a bound color → error. | `InvalidInput`; `PayloadTooLarge` over the weight | all |
| AK-UPDATE-7 | An update of an ended or unknown activity fails. | After `end` → error. | `NotFound` | iOS |
| AK-UPDATE-8 | A handle that only an event named reads its revision from the list before its first update. | Listed at 7 → sends 8. | `NotFound` when the list does not have it | iOS |
| AK-UPDATE-9 | An update that Rust rejects reserves no revision. | A rejected update, then a valid one → the valid one sends 1. | `InvalidInput` | all |
| AK-UPDATE-10 | The same revision with the same values and stale date succeeds without another ActivityKit call, whatever its timestamp; with other content it fails. | Revision 2 sent twice, with different timestamps → one call. | `Conflict` | iOS |
| AK-UPDATE-11 | Every start, update and end carries a timestamp: the one `Update::timestamp` or `End::timestamp` gives, else the time the handle sends the content; ActivityKit gets it on iOS 17.2. | `Update::new(..)` sent later → the time it was sent; `.timestamp(t)` → t. | `InvalidInput` (before 1970, after the largest time) | iOS 16.2+; passed on 17.2+ |
| AK-UPDATE-12 | An update or an end without a relevance keeps the activity's score. | Started at 50, updated and then ended with the system's default without one → ActivityKit still shows 50. | — | iOS 16.2+ |
| AK-UPDATE-13 | Each content has its own stale date: an update without one clears it; a stale date in the past is allowed. | A stale date, then an update without → `stale_at()` is `None`. | — | iOS 16.2+ |
| AK-UPDATE-14 | Timestamps follow revisions: content built in one order and sent in the other still gets timestamps that grow with its revisions. | Update A built, then B; B sent, then A → revision 1 has the older timestamp. | — | all |
| AK-UPDATE-15 | A write that fails keeps its revision reserved: the next one skips it, and a list that reports a lower revision does not lower the reservation, so no revision is sent twice. | A failed update at 1, a list at 0, then an update → sends 2. | — | all |
| AK-UPDATE-16 | Content with a timestamp older than the shown content's: ActivityKit drops it, while the update succeeds and the handle and the list report its values. An end without values after it ends with those dropped values, made at the time of the end, so ActivityKit shows them; `End::values` ends with others. | An update an hour older than the shown one → the Lock Screen keeps the newer content, also 2 s later; then `End::immediately()` → final content with the dropped values and a newer timestamp. | — | iOS 17.2+ |
| AK-UPDATE-18 | `Update::revision` and `End::revision` send the revision the caller chose instead of the next one, and never retry it. The Swift layer applies the contract: a higher revision is taken, the accepted one with the same content succeeds again, a lower one is `StaleRevision`, the accepted one with other content `Conflict`. Automatic numbering continues above the highest revision sent. | At 3: `revision(7)` → 7, the next automatic update 8; `revision(7)` again with the same values → ok; with others → `Conflict`; `revision(2)` → `StaleRevision`. | `StaleRevision`, `Conflict` | all |
| AK-UPDATE-17 | A write waits for the answer of the one before it, at most the call wait (AK-BRIDGE-11). The Swift layer runs the calls of all activities one at a time too, so a write that overtook one still in flight could end the activity with older values (the review's B1). A reply that the bridge drops unanswered, as when the kit goes away, fails its write and lets the next one go. | A reply held → a later end stays pending and sends nothing; released → the end goes out with the update's values. The reply dropped → the update fails, the end goes out. | `Native` for the write whose reply was dropped | all |

## End

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-END-1 | `End::immediately()` removes the activity at once; the handle reports `Ended`, and ActivityKit then reports `Dismissed`. | → policy `immediate`. | — | iOS 16.2+ |
| AK-END-2 | `End::default()` leaves the dismissal to the system, which keeps the ended activity on the Lock Screen, for up to four hours. | → policy `default`; still listed `Ended` 5 s later. | — | iOS 16.2+ |
| AK-END-3 | `End::after(t)` takes any time up to the largest; the system removes the ended activity at `t` or four hours after the end, whichever comes first, and at once for a time in the past. | → policy `after` with `t` in epoch ms; `now + 8 s` → dismissed at that time; `now − 60 s` → dismissed at once. | `InvalidInput` (before 1970, after the largest time) | iOS 16.2+ |
| AK-END-4 | Ending an activity again succeeds with the same record. | Three ends → three successes. | — | iOS |
| AK-END-5 | Without `End::values` the activity ends with its last accepted values, those of the updates polled before the end, which it waits for (AK-UPDATE-17), at the next revision; an end request without final content ends with the content shown. | An update whose future was dropped, then an end → the end carries the update's values. | — | iOS |
| AK-END-6 | `End` carries final content: values, a stale date and a relevance, checked like an update. | `End::immediately().values(..)` → the activity ends showing them. | `InvalidInput`, `StaleRevision`, `Conflict`, `PayloadTooLarge` | iOS 16.2+ |
| AK-END-7 | Times are epoch milliseconds from 0 to 8 640 000 000 000 000: an `End::after` time, a stale date or a timestamp outside that range fails before anything is sent. | `End::after` at the largest time → sent; one millisecond later → error. | `InvalidInput` | all |

## States

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-STATE-1 | `State` is `Pending`, `Active`, `Stale`, `Ended`, `Dismissed` or `Unknown`, leaves room for more, and reads a state this version does not know as `Unknown`. | `pending` → `Pending`; `paused` → `Unknown`; a match without `_` does not compile. | — | iOS 16.2+; `Pending` 26+ |
| AK-STATE-2 | `Event::State` reports ActivityKit's transitions, an end and its dismissal included. | An immediate end → `Ended` on the handle, then `Dismissed` from ActivityKit. | — | iOS 16.2+ |
| AK-STATE-3 | Transitions while the app was not running are not replayed; `activities()` gives the current state after a launch. | — | — | iOS 16.2+ |
| AK-PLATFORM-1 | Live Activities need an iPhone with iOS 16.2 or an iPad with iPadOS 17; an iOS app on a Mac has none. | iPhone 16.1 → unsupported; 16.2 → supported. | `Unsupported` | iOS |

## Activities after a relaunch

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-LIST-1 | `activities()` returns every activity ActivityKit knows, with its accepted revision, values and state; a handle continues the revision, also after a relaunch. | Revision 1 before the relaunch → `revision()` = 1; the next update sends 2. | `Unsupported` off iOS | iOS 16.2+ |
| AK-LIST-2 | While a handle of an activity lives, every list, event and start gives that same handle. | — | — | all |
| AK-LIST-4 | With `Receipts::Redacted` the receipt file keeps each activity's key, state, accepted revision and a SHA-256 digest of its content without the timestamp, never its values. After a relaunch `activities()` lists what ActivityKit lists, with the values and revision ActivityKit shows (while ActivityKit lags behind an accepted update, its older content); an ended activity that ActivityKit no longer lists is not listed, and ending it again answers its record without values. A digest of guessable values can be guessed, and so can the start's fingerprint (a SHA-256 of the layout and the first values), which the receipt and ActivityKit's attributes (`initialFingerprint`) keep in either mode. ActivityKit itself keeps the values in the activity's content. | Started and updated with secret text → the file holds no text; after a relaunch → listed with the text ActivityKit shows. | — | iOS |
| AK-LIST-3 | Receipts keep the accepted revision when ActivityKit reports an update late, across a restart; an activity ActivityKit no longer lists is never reported active. A receipt holds the activity's key and last accepted values in plain text in Application Support (`activitykit/receipts-v2.json`, mode 0600, on iOS protected until the first unlock after a restart). | — | `Native` for an unreadable receipt file | iOS |

## Events

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-EVENT-1 | A tap on a button arrives as `Event::Action` with the button's action id and the activity's handle, the one the app holds. | Stop tapped on the Lock Screen → `Action { action: "stop" }` with the started handle at revision 1. | — | iOS 17+ |
| AK-EVENT-2 | Lifecycle changes arrive as `Event::State` (`Active`, `Stale`, `Ended`, `Dismissed`, `Unknown`) and set the handle's state. | A start → `Active`; an end → `Dismissed`. | — | iOS 16.2+; `Pending` 26+ |
| AK-EVENT-3 | Every receiver gets the events in the order the Swift layer reported them. | — | — | all |
| AK-EVENT-4 | Events before the first receiver wait for it, the newest 16; a tap before Rust registers waits in Swift. | 18 taps, then a receiver → the newest 16, in order. | — | all |
| AK-EVENT-5 | Each receiver, also one from a clone, gets every event; a dropped receiver gets nothing more and holds nothing up. | — | — | all |
| AK-EVENT-6 | A tap waits until every receiver has handled it (AK-EVENT-14), at most 4 s, less than the 5 s for which its intent posts it until acknowledged, once; a receiver dropped meanwhile stops holding it; starts, states and authorization changes do not wait. | Receivers that read at once and after 150 ms → the tap returns after the second took it. | — | iOS 17+ |
| AK-EVENT-7 | An event this version cannot read is dropped. | An unknown type or missing members → no event. | — | all |
| AK-EVENT-8 | An activity that begins while the app runs arrives as `Event::Started`: one the app started, with its handle, or one the system or a push started. | A start → `Started` with the started handle. | — | iOS 16.2+ |
| AK-EVENT-9 | The receiver is also a `futures_core::Stream`. | `StreamExt::next` gives the next event. | — | all |
| AK-EVENT-10 | `Event` and its variants leave room to grow: a pattern needs `..` and a `_` arm. | A pattern without `..` does not compile. | — | all |
| AK-EVENT-11 | After every receiver is dropped, new events wait again for the next receiver, the newest 16. | Two receivers dropped, then two events → the next receiver gets both. | — | all |
| AK-EVENT-12 | A tap for an activity that ActivityKit no longer lists comes with a handle whose `key()` is empty; its update fails. | — | `NotFound` | iOS 17+ |
| AK-EVENT-14 | `Event::Action` carries an `Acknowledgement`: the tap holds its intent, and so an app that the system launched for it, until every receiver's event and its clones are dropped or `acknowledge()` is called, at most the tap's wait. An app that handles a tap on another thread keeps the event, or its acknowledgement, until it is done, and only while it acts on it: taps go to the app one at a time, so a held tap holds the later ones behind it, and a later tap's intent (5 s) can give up before its tap is taken, which then still arrives. | A handler that keeps the event while it updates the activity → the tap returns after the update, within the wait; `acknowledge()` while keeping it → at once; on the simulator a handler that updates and takes 1 s → the intent's acknowledgement comes after it; a tap held 300 ms → an intent that waits 100 ms gives up, its tap arrives afterwards. | — | iOS 17+ |
| AK-EVENT-13 | Receivers are unbounded: one that is never read keeps every event and holds each tap for the whole wait. | Three taps with an unread receiver → each waits 4 s; the receiver holds three. | — | all |

## Handles

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-HANDLE-1 | Dropping a handle, every handle and the kit, or ending the process never ends an activity. | — | — | all |
| AK-HANDLE-2 | Handles compare by activity id; `Debug` shows id, key, state and revision, never values. | — | — | all |
| AK-HANDLE-3 | `state()`, `values()`, `revision()`, `timestamp()`, `stale_at()`, `relevance()` and `degraded_features()` give what the last reply or event said; `timestamp()` is the content's, as ActivityKit or the receipts keep it. | — | — | all |

## Threads

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-THREAD-1 | Every call is safe from any thread, also at the same time. | Starts from 8 threads → 8 activities, one reply each. | — | all |
| AK-THREAD-2 | The futures are `Send` and need no particular executor; `ActivityKit`, `Activity`, `Event` and `Error` are `Send + Sync`. | A future driven by `block_on` on a worker thread completes. | — | all |
| AK-THREAD-3 | Dropping a future after its request went out does not cancel the request: a write's reply still reaches the handle, and the kit keeps working. | A start polled once and dropped → the activity runs and is listed; an update dropped the same way → the handle reports its revision. | — | all |

## Images, custom views and fonts

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-IMAGE-1 | An image name is `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`. | `../a.png` → error. | `InvalidInput` | all |
| AK-IMAGE-2 | The bytes are a whole PNG: signature, an image header of at least 1 × 1, the end chunk. | GIF bytes → error. | `InvalidInput` | all |
| AK-IMAGE-3 | A PNG is at most 1 MiB and 1224 × 480 pixels. | 1225 pixels wide → error. | `PayloadTooLarge` | all |
| AK-IMAGE-4 | `write_image` writes the whole file at once into `activitykit/images` of the widget's App Group, which it asks Swift for once. | Two writes → the second file, no partial one. | `Native` when the write fails | iOS |
| AK-IMAGE-5 | Without an App Group named under `ActivityKitAppGroup` in the widget's Info.plist, `write_image` fails. | — | `ConfigurationRequired` | iOS |
| AK-IMAGE-6 | Off iOS, `write_image` checks the image, then fails. | — | `Unsupported` | off iOS |
| AK-IMAGE-7 | The size is checked first and exactly: one byte over 1 MiB is too large whatever the bytes are; a write that fails leaves no hidden file, and writes of one name from many threads leave one whole PNG. | 1 MiB + 1 byte of zeros → `PayloadTooLarge`. | `PayloadTooLarge`, `Native` | all |
| AK-CUSTOM-1 | A custom node has a name of the file-name rule and 1 to 16 props: text, a number, a flag, or bound to a value. | 18 props → error. | `InvalidInput` | all |
| AK-CUSTOM-2 | The registered view gets the literal props and the bound ones with the current values. | — | — | iOS 16.2+ |
| AK-CUSTOM-3 | A name with no registered view draws nothing and is reported as `layout.custom.<name>` in `degraded_features()`. | No `ActivityKitCustomViews` class in the app → `["layout.custom.ring"]`. | — | iOS 16.2+ |
| AK-FONT-1 | `font_family` names a font of the widget extension (not together with `design`) and draws with it at the style's size; an unknown font draws the system font. | `fontFamily` with `design` → error. | `InvalidInput` | iOS 16.2+ |

## Layout, values, errors and the contract

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-LAYOUT-1 | Each node builder writes its node of the contract. | `button("stop", text("Stop"))` → `{type: button, actionId, child}`. | — | all |
| AK-LAYOUT-2 | A modifier sets its member on the nodes it belongs to and leaves other nodes as they are. | `text("a").spacing(1)` → unchanged. | — | all |
| AK-LAYOUT-3 | Style builders write every member; seven members and the two tints take `Bound`; a color string is a name or a hex color. | — | — | all |
| AK-LAYOUT-4 | The island and the tints have builders for every region. | — | — | all |
| AK-VALUE-1 | `values!` and the conversions build the values map: text, numbers, flags. | `values!{"level" => 3}` → `3.0`. | — | all |
| AK-ERROR-1 | Each code of the contract is one `Error` variant both ways; `code()` gives it; an unknown code is `Native`. | — | — | all |
| AK-ERROR-2 | Messages are constant text and never repeat a request. | — | — | all |
| AK-ERROR-3 | `UnsupportedFeature` names the feature and the iOS it needs, before anything reaches ActivityKit. | `{feature: "transient", minimumIos: "18.0"}` → `UnsupportedFeature { feature: "transient", minimum_ios: (18, 0) }`. | `Native` when a member is missing | all |
| AK-ERROR-4 | `SystemLimit` says whether the app's or the device's limit was reached. | `targetMaximumExceeded` → `App`; `globalMaximumExceeded` → `Device`. | — | all |
| AK-ERROR-5 | `Error` and `LimitScope` leave room for more: a match needs a `_` arm. | A match without `_` does not compile. | — | all |
| AK-DOCS-1 | The docs and the rustdoc state the 8-hour and 12-hour limits, the four-hour dismissal, what an alert shows, that relevance is kept and stale dates clear, that dropping ends or cancels nothing, and what is not supported yet. | — | — | all |
| AK-CONTRACT-1 | The Rust validator gives every fixture its verdict, code and weight. | 1048 requests and 34 updates. | `InvalidInput`, `PayloadTooLarge` | all |
| AK-CONTRACT-2 | The Swift validator gives every fixture the same. | — | the same | Mac host |
| AK-CONTRACT-3 | Every fixture sent through the C functions gets the same answer. | — | the same | Mac host |
| AK-CONTRACT-4 | An update is checked against its start: keys, types, references, weight. | — | `InvalidInput`, `PayloadTooLarge` | all |
| AK-CONTRACT-5 | Input is strict: unknown members, `null`, wrong types and JSON nested too deep are rejected, a request must read back as itself, and only the three v2 requests exist. | — | `InvalidInput` | all |
| AK-CONTRACT-6 | The payload weight follows the contract's formula in Rust and Swift. | `{lockScreen: text Hello}` → 52. | — | all |
| AK-CONTRACT-7 | Path data follows the contract's grammar, not an SVG parser's. | `M0 0 A…` → error. | `InvalidInput` | all |
| AK-CONTRACT-8 | A tree is at most 8 deep; regions have their node and button limits. | 41 nodes on the Lock Screen → error. | `InvalidInput` | all |
| AK-CONTRACT-9 | References between layout, styles and values hold, bound members included. | A bound size of 200 → error. | `InvalidInput` | all |
| AK-CONTRACT-10 | Each rule of requests, values, styles and nodes rejects what breaks it and takes its limits. | — | `InvalidInput` | all |
| AK-CONTRACT-11 | A number read from JSON text keeps the value that was written. | `96.00000000000001` stays outside 6..96. | `InvalidInput` | all |
| AK-CONTRACT-12 | Snapshots take an optional `timestamp`, `end_layout` optional final content, records a `relevance`, in every layer. | The fixtures with these members. | `InvalidInput`, `PayloadTooLarge` | all |
| AK-CONTRACT-13 | A record carries what ActivityKit knows and nothing of other platforms: `id`, `activityKey`, `schemaVersion`, `snapshot`, `state`, `degradedFeatures` and, when known, `relevance`; no `backend`, `visibility`, `promotionRequested` or `promotionState`, which a cross-platform layer adds at its own boundary. A reader passes over members it does not know, so a record written by 0.1 still reads. | The record of a start → those members and no other. | — | all |

## The C bridge

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-BRIDGE-1 | A request that is not JSON, or not the request's shape, is answered `INVALID_INPUT`, once. | `not json`, `[]`, `{"request":null}` → error. | `InvalidInput` | iOS |
| AK-BRIDGE-2 | An unknown handle is answered `NOT_FOUND`. | — | `NotFound` | iOS |
| AK-BRIDGE-3 | `ak_start`, `ak_update`, `ak_end` and `ak_list` reply exactly once, later; `ak_authorization` and `ak_image_folder` reply before they return; any thread may call. | — | — | iOS |
| AK-BRIDGE-4 | A reply that does not fit the envelope is a native error. | — | `Native` | all |
| AK-BRIDGE-5 | Events keep their wire shape; a later handler replaces the earlier one, so only it gets the next event; none drops events; the first starts the observation once, and waiting taps reach a handler. | — | — | iOS |
| AK-BRIDGE-6 | Each asynchronous call checks the platform first. | An unsupported device → `UNSUPPORTED_PLATFORM`, also for a broken request. | `Unsupported` | iOS |
| AK-BRIDGE-7 | Relevance and alert travel beside the contract request and reach ActivityKit during that call only. | — | — | iOS |
| AK-BRIDGE-8 | The library exports the eight C functions by their C symbols. | `nm` and `dlsym` find all eight. | — | iOS |
| AK-BRIDGE-10 | `ak_configure` takes `{"receipts": "full" | "redacted"}`, strictly, and replies before it returns with the settings in force; the first settings hold until the process ends, and the lifecycle's first use fixes the default ones. | `{"receipts":"redacted"}` → those settings; then `full` → `CONFLICT`; `{}` or another member → `INVALID_INPUT`. | `Conflict`, `InvalidInput` | iOS |
| AK-BRIDGE-11 | A call the bridge never answers fails with `Native` once the kit's call wait (10 s) is over, and a reply that comes later changes nothing: not the handle's content, state or revision, not an end made meanwhile, and not the turn of a later write. A write that waited in vain frees its turn. A reply the bridge drops unanswered still fails at once (AK-BRIDGE-9). The wait is the kit's own, with no runtime behind it, and a reply that came inside the call needs none. | A bridge that keeps the reply → `Native` after the wait, the future released; the kept reply delivered later → nothing changes. | `Native` | all |
| AK-BRIDGE-9 | A reply that comes after Rust dropped the future is discarded without a panic on the replying thread; a write's reply still reaches the handle; a reply callback dropped without being called fails its future with `Native`. | — | — | all |

## Build

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-BUILD-1 | On `aarch64-apple-ios`, build.rs builds the bridge for arm64 iPhoneOS and links it. | `platform IOS`, arm64, eight C functions. | a build error naming the failed command | Mac with Xcode |
| AK-BUILD-2 | On `aarch64-apple-ios-sim`, for the arm64 simulator. | `platform IOSSIMULATOR`, arm64. | the same | Mac with Xcode |
| AK-BUILD-3 | On `x86_64-apple-ios`, for the x86_64 simulator. | `platform IOSSIMULATOR`, x86_64. | the same | Mac with Xcode |
| AK-BUILD-4 | On any other target build.rs builds no Swift and needs no Xcode. | Linux or macOS host → no Swift build. | — | all |
| AK-BUILD-5 | Under docs.rs (`DOCS_RS`) or `ACTIVITYKIT_SKIP_SWIFT`, the iOS code type-checks without a Swift build. | `cargo check --target aarch64-apple-ios` without Xcode → passes. | — | any |
| AK-BUILD-6 | The Swift deployment target is `IPHONEOS_DEPLOYMENT_TARGET`, raised to 15.0. | 16.4 → 16.4; 12.0 → 15.0. | — | Mac with Xcode |

## The widget and its renderer

| ID | Behavior | Input → result | Errors | Platform |
| --- | --- | --- | --- | --- |
| AK-WIDGET-1 | A widget extension whose only Swift file is `templates/ios/Widget.swift` draws the app's activities on the Lock Screen, buttons included. | — | — | iOS 16.2+; buttons 17+ |
| AK-WIDGET-2 | A start needs an embedded extension whose Info.plist sets `ActivityKitLayout` to the integer 2. | None, or `"2"`, or 3 → error. | `ConfigurationRequired` | iOS |
| AK-RENDER-1 | Stacks keep their children's order, spacing and alignment; hidden children are left out. | — | — | iOS 16.2+ |
| AK-RENDER-2 | `spacer` takes its least length; `divider` draws a line. | — | — | iOS 16.2+ |
| AK-RENDER-3 | `text` shows its literal or its bound value as given (numbers in their shortest form); a missing value draws nothing. | — | — | iOS 16.2+ |
| AK-RENDER-4 | `symbol` draws the SF Symbol with its rendering and its variable value clamped to 0…1. | — | — | iOS 16.2+ |
| AK-RENDER-5 | `image` draws an asset of the extension, or a file from the App Group folder; a missing one draws nothing. | — | — | iOS 16.2+ |
| AK-RENDER-6 | `path` draws its commands scaled into its box, filled or stroked. | — | — | iOS 16.2+ |
| AK-RENDER-7 | `progress` shows its number clamped to 0…1, linear or circular. | — | — | iOS 16.2+ |
| AK-RENDER-8 | `gauge` shows its number clamped to its range, which defaults to 0…1. | — | — | iOS 16.2+ |
| AK-RENDER-9 | `timerText` counts between two epoch-millisecond values, down unless told otherwise. | — | — | iOS 16.2+ |
| AK-RENDER-10 | `button` wraps its label in the action intent on iOS 17; below it shows the label only. | — | — | iOS 16.2+; tap 17+ |
| AK-RENDER-11 | `custom` hands its name and resolved props to the registered view. | — | — | iOS 16.2+ |
| AK-RENDER-12 | `if` and `unless` show a node and its subtree while a value is or is not truthy. | `0`, `""` and `false` are not truthy. | — | iOS 16.2+ |
| AK-RENDER-13 | Styles apply their members in the contract's order; bound members read the current values; a value that does not fit leaves the member out. | — | — | iOS 16.2+ |
| AK-RENDER-14 | An island part that the layout leaves out draws the contract's default. | No island → the first symbol in the compact leading part. | — | iOS 16.2+ |
| AK-RENDER-15 | The background and keyline tints, literal or bound, reach the Lock Screen and the island. | — | — | iOS 16.2+ |
| AK-RENDER-16 | A layout with every node type draws on the Lock Screen, and its button works. | — | — | iOS 17+ |

## Planned

Not built yet ([Not yet supported](not-yet-supported.md)); each becomes a requirement with its tests when it is.

- Transient activities (`Start::transient()`, iOS 18): `UnsupportedFeature` with 18.0 before.
- Scheduled starts (`Start::scheduled(at, alert)`, iOS 26): the alert is required, and the activity is `Pending` until `at`; a key is taken while its activity is pending.
- Frequent pushes (`Authorization.frequent_pushes`, iOS 16.2).
- Alert sounds (`Alert::sound`).
- Push tokens (`PushToken`, lowercase hex `Display`, a new token as an event), content delivered by push that no older receipt hides, the push-to-start token (iOS 17.2) and channels (`ChannelId`, base64, iOS 18).
- `ActivityKit::new()` early at launch receives the tokens and new activities that wake the app in the background, as it receives taps now.

## Not proven by a test

- AK-AUTH-3, AK-AUTH-5: No test turns Live Activities off in Settings, so ActivityKit's own `activityEnablementUpdates` is not driven; the tests drive the watcher with a source of their own and the event through the bridge and Rust.
- AK-START-8: The switch from `ActivityAuthorizationError` to the name of its case runs only on iOS, and no test makes ActivityKit refuse a start that way except `visibility` (AK-START-10); the table from the name to the code is tested.
- AK-START-9: The `NSSupportsLiveActivities` check runs only on iOS, and the test host always has the key.
- AK-STATE-1, AK-STATE-2: `Pending` needs a scheduled start, which the crate does not offer yet, and the system's end after 8 hours takes longer than a test. `Stale` was tried on the iOS 26.3 simulator with `Start::stale_at(now + 3 s)` and the app in the foreground (40 s) and with `now + 12 s` and the Lock Screen pulled down (25 s): ActivityKit reported no `stale` state, by event or in its list, so no test asserts it. The mapping of these states is tested with events.
- AK-RENDER-10, AK-AUTH-1, AK-UPDATE-11: iOS 16.2 to 17.1: buttons that show their label only, `buttons` false on iOS 16, and content sent without a timestamp below 17.2 (the `#available(iOS 17.2)` branch). No simulator of those versions runs here or in CI; the tests run iOS 26.
- AK-END-3: The four-hour limit of `End::after` and `End::default` is the system's; the tests see a dismissal at a time eight seconds ahead and at once for a past time, not after four hours.
- AK-EVENT-6: A tap that launches the app from not running is not tested; the tests tap while the app runs in the background.
- AK-RENDER-1 to AK-RENDER-15: On the Mac the renderer is tested where it turns a layout and values into resolved nodes; the SwiftUI drawing of each node runs only on iOS, where the test host draws layouts on the Lock Screen and checks what it can read there, not pixels.
- AK-BUILD-2: On an Intel Mac the `aarch64-apple-ios-sim` Rust target is not installed; CI's Apple-silicon runner builds it.

## Tests

| Requirement | Tests |
| --- | --- |
| AK-KIT-1 | `src/kit/tests.rs::futures_are_send_and_types_are_send_and_sync` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-KIT-2 | `src/kit/tests.rs::off_ios_every_call_is_unsupported_after_the_contract_check` (unit)<br>`src/bridge.rs::no_bridge_answers_unsupported` (unit) |
| AK-KIT-3 | `src/kit/setting_tests.rs::the_first_settings_hold_and_others_conflict` (unit)<br>`src/kit/setting_tests.rs::build_hands_its_settings_to_the_bridge` (unit)<br>`src/kit/setting_tests.rs::the_first_use_fixes_the_default_settings` (unit)<br>`src/kit/setting_tests.rs::off_ios_build_succeeds_and_every_call_stays_unsupported` (unit)<br>`tests/swift/settings.swift::testSettings` (Swift host)<br>`tests/ios-host/src/lib.rs::redacted_start` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testRedactedReceiptsAfterRelaunch` (simulator) |
| AK-KIT-4 | `src/kit/setting_tests.rs::activity_finds_a_handle_by_id` (unit)<br>`tests/ios-host/src/lib.rs::relaunch_check` (simulator) |
| AK-AUTH-1 | `src/kit/tests.rs::authorization_reads_the_bridge` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeAuthorizationAndImages` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeFromManyThreads` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator) |
| AK-AUTH-2 | `src/kit/tests.rs::authorization_reads_the_bridge` (unit)<br>`src/kit/tests.rs::swift_errors_keep_their_codes_and_messages` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeAuthorizationAndImages` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-AUTH-3 | `src/kit/tests.rs::every_subscriber_gets_every_event_with_the_shared_handle` (unit)<br>`src/kit/tests.rs::every_receiver_gets_the_events_in_the_order_they_came` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeEvents` (Swift host)<br>`tests/swift/mapping.swift::testAuthorizationWatcher` (Swift host) |
| AK-AUTH-5 | `tests/swift/mapping.swift::testAuthorizationWatcher` (Swift host) |
| AK-AUTH-4 | `src/kit/tests.rs::authorization_reads_the_bridge` (unit) |
| AK-AUTH-6 | `src/kit/event_tests.rs::authorization_does_not_check_the_apps_setup` (unit) |
| AK-AUTH-7 | `src/kit.rs::Authorization` (doc) |
| AK-START-1 | `src/kit/tests.rs::start_sends_the_contract_request_and_returns_a_handle` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator) |
| AK-START-2 | `src/kit/tests.rs::start_sends_the_contract_request_and_returns_a_handle` (unit) |
| AK-START-3 | `src/kit/tests.rs::start_options_reach_the_request` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeKeyedStart` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host)<br>`tests/ios-host/src/lib.rs::relaunch_start` (simulator)<br>`tests/ios-host/src/lib.rs::relaunch_check` (simulator)<br>`tests/ios-host/src/lib.rs::redacted_check` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testActivitiesAfterRelaunch` (simulator) |
| AK-START-4 | `src/kit/tests.rs::start_options_reach_the_request` (unit)<br>`src/kit/tests.rs::a_request_that_breaks_the_contract_never_reaches_the_bridge` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-START-5 | `src/kit/tests.rs::a_request_that_breaks_the_contract_never_reaches_the_bridge` (unit)<br>`src/kit/tests.rs::off_ios_every_call_is_unsupported_after_the_contract_check` (unit)<br>`tests/contract.rs::every_fixture_gets_its_verdict_code_and_weight` (unit)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host) |
| AK-START-6 | `src/kit/tests.rs::a_request_that_breaks_the_contract_never_reaches_the_bridge` (unit)<br>`src/contract/limit_tests.rs::layout_styles_and_values_weigh_at_most_3584_together` (unit)<br>`tests/contract.rs::the_weight_limit_is_a_payload_error_only_for_an_otherwise_valid_request` (unit)<br>`tests/swift/layout-lifecycle.swift::testNativeSizeCheck` (Swift host) |
| AK-START-7 | `src/kit/tests.rs::off_ios_every_call_is_unsupported_after_the_contract_check` (unit)<br>`src/kit/tests.rs::swift_errors_keep_their_codes_and_messages` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeUnsupported` (Swift host)<br>`tests/swift/platform-support.swift::testPlatformSupport` (Swift host) |
| AK-START-8 | `src/kit/tests.rs::swift_errors_keep_their_codes_and_messages` (unit)<br>`src/error.rs::every_code_reads_back_as_itself` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host)<br>`tests/swift/mapping.swift::testErrorTable` (Swift host) |
| AK-START-9 | `tests/swift/layout-lifecycle.swift::testLayoutWidgetPreflight` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host) |
| AK-START-12 | `src/kit/setting_tests.rs::a_start_takes_its_revision_and_timestamp` (unit) |
| AK-START-10 | `src/kit/tests.rs::swift_errors_keep_their_codes_and_messages` (unit)<br>`tests/swift/mapping.swift::testErrorTable` (Swift host)<br>`tests/ios-host/src/lib.rs::background_start` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testBackgroundStartIsNotForeground` (simulator) |
| AK-START-11 | `tests/ios-host/src/lib.rs::background_start` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testBackgroundStartIsNotForeground` (simulator) |
| AK-UPDATE-1 | `src/kit/tests.rs::updates_carry_the_next_revision_and_their_options` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator) |
| AK-UPDATE-2 | `src/kit/tests.rs::updates_carry_the_next_revision_and_their_options` (unit)<br>`src/kit/tests.rs::a_request_that_breaks_the_contract_never_reaches_the_bridge` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-UPDATE-3 | `src/kit/tests.rs::clones_share_the_revision_and_concurrent_updates_never_reuse_one` (unit)<br>`src/kit/write_tests.rs::an_end_racing_an_update_ends_with_that_updates_values` (unit)<br>`src/kit/write_tests.rs::writes_go_out_in_the_order_their_futures_are_first_polled` (unit)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host) |
| AK-UPDATE-4 | `src/kit/tests.rs::a_stale_revision_refreshes_from_the_list_and_retries_once_when_newer` (unit)<br>`src/kit/write_tests.rs::the_retry_after_a_stale_revision_compares_timestamps` (unit)<br>`src/kit/write_tests.rs::an_end_retries_once_after_a_stale_revision` (unit)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host) |
| AK-UPDATE-5 | `tests/swift/layout-render.swift::testRenderBoundStyles` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testBoundStyleUpdates` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-UPDATE-6 | `src/kit/tests.rs::a_request_that_breaks_the_contract_never_reaches_the_bridge` (unit)<br>`src/contract/limit_tests.rs::an_update_is_checked_against_its_start` (unit)<br>`tests/contract.rs::every_update_fixture_is_checked_against_its_start` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeFixtures` (Swift host) |
| AK-UPDATE-7 | `src/kit/tests.rs::end_sends_its_policy_and_the_handle_reports_the_state` (unit)<br>`src/kit/tests.rs::a_handle_that_only_an_event_named_learns_its_revision_from_the_list` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-UPDATE-8 | `src/kit/tests.rs::a_handle_that_only_an_event_named_learns_its_revision_from_the_list` (unit) |
| AK-UPDATE-9 | `src/kit/tests.rs::a_request_that_breaks_the_contract_never_reaches_the_bridge` (unit) |
| AK-UPDATE-10 | `tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testTimestampIsNotContent` (Swift host)<br>`tests/swift/receipts.swift::testFullLayoutReceipts` (Swift host)<br>`tests/swift/receipts.swift::testRedactedDigestOfContent` (Swift host) |
| AK-UPDATE-11 | `src/kit/tests.rs::starts_updates_and_ends_carry_their_timestamp` (unit)<br>`src/kit/write_tests.rs::timestamps_are_taken_when_the_content_is_sent` (unit)<br>`tests/swift/mapping.swift::testSnapshotTimestamps` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeEndContent` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator) |
| AK-UPDATE-12 | `src/kit/tests.rs::relevance_is_kept_and_the_stale_date_follows_each_update` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/src/lib.rs::policies` (simulator)<br>`tests/ios-host/UITests/PolicyTests.swift::testDismissalsAndRelevance` (simulator) |
| AK-UPDATE-13 | `src/kit/tests.rs::relevance_is_kept_and_the_stale_date_follows_each_update` (unit)<br>`src/kit/write_tests.rs::times_beyond_the_largest_are_invalid_and_a_past_stale_date_is_not` (unit) |
| AK-UPDATE-14 | `src/kit/write_tests.rs::timestamps_are_taken_when_the_content_is_sent` (unit) |
| AK-UPDATE-15 | `src/kit/write_tests.rs::a_failed_write_keeps_its_revision_reserved` (unit) |
| AK-UPDATE-16 | `src/kit/write_tests.rs::an_end_without_values_after_an_older_update_carries_that_updates_values` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-UPDATE-18 | `src/kit/setting_tests.rs::updates_and_ends_send_the_revision_the_caller_chose` (unit)<br>`tests/swift/layout-lifecycle.swift::testTimestampIsNotContent` (Swift host) |
| AK-UPDATE-17 | `src/kit/write_tests.rs::a_held_reply_holds_every_later_write_until_it_comes` (unit)<br>`src/kit/write_tests.rs::a_dropped_reply_fails_its_write_and_passes_the_turn_on` (unit)<br>`tests/swift/layout-lifecycle.swift::testOneCallAtATime` (Swift host) |
| AK-END-1 | `src/kit/tests.rs::end_sends_its_policy_and_the_handle_reports_the_state` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator) |
| AK-END-2 | `src/kit/tests.rs::end_sends_its_policy_and_the_handle_reports_the_state` (unit)<br>`tests/ios-host/src/lib.rs::policies` (simulator)<br>`tests/ios-host/UITests/PolicyTests.swift::testDismissalsAndRelevance` (simulator) |
| AK-END-3 | `src/kit/tests.rs::end_sends_its_policy_and_the_handle_reports_the_state` (unit)<br>`src/kit/write_tests.rs::an_end_after_takes_any_time_up_to_the_largest` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeFixtures` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host)<br>`tests/ios-host/src/lib.rs::policies` (simulator)<br>`tests/ios-host/UITests/PolicyTests.swift::testDismissalsAndRelevance` (simulator) |
| AK-END-4 | `src/kit/tests.rs::end_sends_its_policy_and_the_handle_reports_the_state` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host) |
| AK-END-5 | `src/kit/tests.rs::end_sends_its_policy_and_the_handle_reports_the_state` (unit)<br>`src/kit/tests.rs::an_end_carries_its_final_content` (unit)<br>`src/kit/write_tests.rs::an_end_after_a_dropped_update_ends_with_that_updates_values` (unit)<br>`src/kit/write_tests.rs::an_end_racing_an_update_ends_with_that_updates_values` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeEndContent` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host)<br>`tests/swift/receipts.swift::testRedactedEndAfterRestart` (Swift host) |
| AK-END-6 | `src/kit/tests.rs::an_end_carries_its_final_content` (unit)<br>`src/kit/write_tests.rs::an_end_retries_once_after_a_stale_revision` (unit)<br>`tests/contract.rs::every_end_fixture_is_checked_against_its_start` (unit)<br>`tests/swift/mapping.swift::testEndWithFinalContent` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeEndContent` (Swift host)<br>`tests/swift/layout-fixtures.swift::testLayoutFixtures` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/src/lib.rs::policies` (simulator)<br>`tests/ios-host/UITests/PolicyTests.swift::testDismissalsAndRelevance` (simulator) |
| AK-END-7 | `src/kit/write_tests.rs::an_end_after_takes_any_time_up_to_the_largest` (unit)<br>`src/kit/write_tests.rs::times_beyond_the_largest_are_invalid_and_a_past_stale_date_is_not` (unit)<br>`tests/contract.rs::every_fixture_gets_its_verdict_code_and_weight` (unit) |
| AK-STATE-1 | `src/kit/tests.rs::state_events_carry_every_state` (unit)<br>`src/contract/mod.rs::State` (doc) |
| AK-STATE-2 | `src/kit/tests.rs::state_events_carry_every_state` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator) |
| AK-STATE-3 | `src/kit/tests.rs::a_handle_after_a_relaunch_continues_from_the_listed_revision` (unit)<br>`tests/ios-host/src/lib.rs::relaunch_check` (simulator) |
| AK-PLATFORM-1 | `tests/swift/platform-support.swift::testPlatformSupport` (Swift host) |
| AK-LIST-1 | `src/kit/tests.rs::a_handle_after_a_relaunch_continues_from_the_listed_revision` (unit)<br>`tests/ios-host/src/lib.rs::relaunch_check` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testActivitiesAfterRelaunch` (simulator) |
| AK-LIST-2 | `src/kit/tests.rs::a_handle_after_a_relaunch_continues_from_the_listed_revision` (unit)<br>`src/kit/tests.rs::every_subscriber_gets_every_event_with_the_shared_handle` (unit) |
| AK-LIST-4 | `tests/swift/receipts.swift::testRedactedLayoutReceipts` (Swift host)<br>`tests/swift/receipts.swift::testRedactedDigestOfContent` (Swift host)<br>`tests/swift/settings.swift::testSettings` (Swift host)<br>`tests/ios-host/src/lib.rs::redacted_start` (simulator)<br>`tests/ios-host/src/lib.rs::redacted_check` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testRedactedReceiptsAfterRelaunch` (simulator) |
| AK-LIST-3 | `tests/swift/receipts.swift::testFullLayoutReceipts` (Swift host)<br>`tests/swift/receipts.swift::testReceiptFileRules` (Swift host)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host) |
| AK-EVENT-1 | `src/kit/tests.rs::every_subscriber_gets_every_event_with_the_shared_handle` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeEvents` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-EVENT-2 | `src/kit/tests.rs::state_events_carry_every_state` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeEvents` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-EVENT-3 | `src/kit/tests.rs::every_receiver_gets_the_events_in_the_order_they_came` (unit)<br>`src/kit/tests.rs::events_before_the_first_subscriber_wait_for_it` (unit)<br>`tests/swift/actions.swift::testActionRelay` (Swift host) |
| AK-EVENT-4 | `src/kit/tests.rs::events_before_the_first_subscriber_wait_for_it` (unit)<br>`tests/swift/actions.swift::testActionRelay` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeEvents` (Swift host) |
| AK-EVENT-5 | `src/kit/tests.rs::every_subscriber_gets_every_event_with_the_shared_handle` (unit)<br>`src/kit/tests.rs::every_receiver_gets_the_events_in_the_order_they_came` (unit)<br>`src/kit/tests.rs::the_wait_for_a_tap_is_bounded` (unit)<br>`src/kit/event_tests.rs::a_receiver_dropped_while_a_tap_waits_releases_it` (unit) |
| AK-EVENT-6 | `src/kit/tests.rs::a_tap_returns_once_every_subscriber_has_taken_it` (unit)<br>`src/kit/tests.rs::the_wait_for_a_tap_is_bounded` (unit)<br>`src/kit/event_tests.rs::a_tap_waits_for_the_slowest_receiver` (unit)<br>`src/kit/event_tests.rs::a_receiver_dropped_while_a_tap_waits_releases_it` (unit)<br>`src/kit/event_tests.rs::a_tap_waits_less_than_the_intent_posts_it` (unit)<br>`src/kit/event_tests.rs::only_taps_wait_for_the_receivers` (unit)<br>`tests/swift/actions.swift::testActionRelay` (Swift host)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-EVENT-7 | `src/kit/tests.rs::events_before_the_first_subscriber_wait_for_it` (unit) |
| AK-EVENT-8 | `src/kit/tests.rs::new_activities_arrive_as_started_events` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeEvents` (Swift host)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-EVENT-9 | `src/kit/tests.rs::the_receiver_is_also_a_stream` (unit) |
| AK-EVENT-10 | `src/events.rs::Event` (doc) |
| AK-EVENT-11 | `src/kit/event_tests.rs::after_every_receiver_is_dropped_events_wait_for_the_next_one` (unit)<br>`src/kit/tests.rs::events_before_the_first_subscriber_wait_for_it` (unit) |
| AK-EVENT-12 | `src/kit/tests.rs::a_handle_that_only_an_event_named_learns_its_revision_from_the_list` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeEvents` (Swift host) |
| AK-EVENT-14 | `src/kit/event_tests.rs::a_tap_waits_until_its_event_is_dropped` (unit)<br>`src/kit/event_tests.rs::a_tap_waits_for_a_handler_that_updates_the_activity` (unit)<br>`tests/swift/actions.swift::testActionRelay` (Swift host)<br>`src/kit/event_tests.rs::acknowledging_releases_the_tap_before_the_event_is_dropped` (unit)<br>`src/kit/event_tests.rs::a_tap_waits_for_every_clone_of_its_event` (unit)<br>`src/kit/event_tests.rs::a_tap_waits_for_the_slowest_receiver` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-EVENT-13 | `src/kit/event_tests.rs::an_unread_receiver_keeps_every_event_and_holds_each_tap_for_the_whole_wait` (unit) |
| AK-HANDLE-1 | `src/kit/tests.rs::dropping_a_handle_never_ends_the_activity` (unit)<br>`tests/ios-host/src/lib.rs::relaunch_check` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testActivitiesAfterRelaunch` (simulator) |
| AK-HANDLE-2 | `src/kit/tests.rs::debug_output_names_the_activity_without_its_values` (unit)<br>`src/kit/tests.rs::start_sends_the_contract_request_and_returns_a_handle` (unit) |
| AK-HANDLE-3 | `src/kit/tests.rs::start_sends_the_contract_request_and_returns_a_handle` (unit)<br>`src/kit/tests.rs::updates_carry_the_next_revision_and_their_options` (unit)<br>`src/kit/tests.rs::degraded_features_come_from_the_record` (unit)<br>`src/kit/tests.rs::relevance_is_kept_and_the_stale_date_follows_each_update` (unit)<br>`src/kit/setting_tests.rs::a_start_takes_its_revision_and_timestamp` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/src/lib.rs::relaunch_check` (simulator) |
| AK-THREAD-1 | `src/kit/tests.rs::clones_share_the_revision_and_concurrent_updates_never_reuse_one` (unit)<br>`src/kit/write_tests.rs::starts_from_eight_worker_threads_get_one_activity_each` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeFromManyThreads` (Swift host) |
| AK-THREAD-2 | `src/kit/tests.rs::futures_are_send_and_types_are_send_and_sync` (unit)<br>`src/kit/write_tests.rs::starts_from_eight_worker_threads_get_one_activity_each` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator) |
| AK-THREAD-3 | `src/kit/tests.rs::dropping_a_future_does_not_cancel_its_request` (unit)<br>`src/kit/write_tests.rs::a_dropped_writes_reply_still_reaches_the_handle` (unit)<br>`src/kit/write_tests.rs::an_end_after_a_dropped_update_ends_with_that_updates_values` (unit) |
| AK-IMAGE-1 | `src/image.rs::rejects_names_outside_the_file_rule` (unit)<br>`src/image.rs::takes_a_png_within_the_limits_under_a_file_name` (unit) |
| AK-IMAGE-2 | `src/image.rs::rejects_what_is_not_a_whole_png` (unit)<br>`src/image.rs::the_input_is_strict` (unit) |
| AK-IMAGE-3 | `src/image.rs::a_png_too_large_is_a_payload_error` (unit)<br>`src/image.rs::takes_a_png_within_the_limits_under_a_file_name` (unit)<br>`src/image.rs::the_size_limit_is_exact_and_comes_first` (unit) |
| AK-IMAGE-4 | `src/image.rs::writes_the_png_and_replaces_an_earlier_one_whole` (unit)<br>`src/image.rs::failed_and_concurrent_writes_leave_whole_files_only` (unit)<br>`src/kit/tests.rs::images_go_to_the_folder_the_bridge_names` (unit)<br>`tests/swift/layout-custom.swift::testImageFolder` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeAuthorizationAndImages` (Swift host) |
| AK-IMAGE-5 | `src/kit/tests.rs::images_go_to_the_folder_the_bridge_names` (unit)<br>`tests/swift/layout-custom.swift::testImageFolder` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeAuthorizationAndImages` (Swift host) |
| AK-IMAGE-6 | `src/kit/tests.rs::off_ios_every_call_is_unsupported_after_the_contract_check` (unit) |
| AK-IMAGE-7 | `src/image.rs::the_size_limit_is_exact_and_comes_first` (unit)<br>`src/image.rs::failed_and_concurrent_writes_leave_whole_files_only` (unit) |
| AK-CUSTOM-1 | `src/contract/rule_tests.rs::rejects_each_node_rule` (unit)<br>`src/contract/model_tests.rs::image_sources_and_custom_props_build_their_wire_shape` (unit)<br>`src/layout/tests.rs::modifiers_set_the_members_of_their_nodes` (unit) |
| AK-CUSTOM-2 | `tests/swift/layout-custom.swift::testCustomNodes` (Swift host) |
| AK-CUSTOM-3 | `tests/swift/layout-custom.swift::testCustomNodes` (Swift host)<br>`src/kit/tests.rs::degraded_features_come_from_the_record` (unit)<br>`tests/ios-host/src/lib.rs::lock_screen` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-FONT-1 | `src/contract/rule_tests.rs::rejects_each_style_and_color_rule` (unit)<br>`tests/swift/layout-custom.swift::testFontFamilyAndFileImages` (Swift host) |
| AK-LAYOUT-1 | `src/layout/tests.rs::every_builder_writes_its_node` (unit)<br>`src/layout/tests.rs::the_sketch_layout_builds_its_wire_request` (unit) |
| AK-LAYOUT-2 | `src/layout/tests.rs::modifiers_set_the_members_of_their_nodes` (unit)<br>`src/layout/tests.rs::a_modifier_leaves_other_nodes_as_they_are` (unit) |
| AK-LAYOUT-3 | `src/layout/tests.rs::style_builders_write_every_member` (unit)<br>`src/kit/tests.rs::bound_text_and_wire_values_round_trip` (unit) |
| AK-LAYOUT-4 | `src/layout/tests.rs::layout_and_island_builders_fill_every_region` (unit) |
| AK-VALUE-1 | `src/value.rs::the_macro_and_conversions_build_the_wire_map` (unit)<br>`src/value.rs::values_convert_from_and_into_maps_and_pairs` (unit) |
| AK-ERROR-1 | `src/error.rs::every_code_reads_back_as_itself` (unit)<br>`src/bridge.rs::unwraps_success_and_keeps_the_swift_error_codes` (unit)<br>`src/kit/tests.rs::swift_errors_keep_their_codes_and_messages` (unit) |
| AK-ERROR-2 | `src/bridge.rs::malformed_replies_fail_closed` (unit)<br>`tests/contract.rs::the_weight_limit_is_a_payload_error_only_for_an_otherwise_valid_request` (unit)<br>`tests/contract.rs::every_fixture_error_is_a_constant_text` (unit)<br>`tests/swift/bridge-abi.swift::testBridgeFixtures` (Swift host) |
| AK-ERROR-3 | `src/error.rs::every_code_reads_back_as_itself` (unit)<br>`src/kit/tests.rs::swift_errors_keep_their_codes_and_messages` (unit)<br>`tests/swift/mapping.swift::testFailureMembers` (Swift host) |
| AK-ERROR-4 | `src/error.rs::every_code_reads_back_as_itself` (unit)<br>`src/kit/tests.rs::swift_errors_keep_their_codes_and_messages` (unit)<br>`tests/swift/mapping.swift::testErrorTable` (Swift host)<br>`tests/swift/mapping.swift::testFailureMembers` (Swift host) |
| AK-ERROR-5 | `src/error.rs::Error` (doc)<br>`src/error.rs::LimitScope` (doc) |
| AK-DOCS-1 | `tests/docs.rs::the_docs_state_the_system_limits_and_behaviors` (unit)<br>`tests/docs.rs::no_doc_says_what_is_no_longer_true` (unit) |
| AK-CONTRACT-1 | `tests/contract.rs::every_fixture_gets_its_verdict_code_and_weight` (unit)<br>`tests/contract.rs::valid_fixtures_keep_their_verdict_and_weight_through_the_typed_models` (unit) |
| AK-CONTRACT-2 | `tests/swift/layout-fixtures.swift::testLayoutFixtures` (Swift host) |
| AK-CONTRACT-3 | `tests/swift/bridge-abi.swift::testBridgeFixtures` (Swift host) |
| AK-CONTRACT-4 | `tests/contract.rs::every_update_fixture_is_checked_against_its_start` (unit)<br>`src/contract/limit_tests.rs::an_update_is_checked_against_its_start` (unit)<br>`tests/swift/layout-fixtures.swift::testLayoutFixtures` (Swift host) |
| AK-CONTRACT-5 | `src/contract/model_tests.rs::models_reject_unknown_members_null_and_wrong_types` (unit)<br>`src/contract/model_tests.rs::a_request_must_re_encode_to_itself` (unit)<br>`src/contract/model_tests.rs::numbers_compare_by_value_and_deep_json_is_refused_unread` (unit)<br>`tests/contract.rs::only_the_v2_commands_are_taken` (unit)<br>`tests/swift/layout-fixtures.swift::testLayoutFixtures` (Swift host) |
| AK-CONTRACT-6 | `src/contract/model_tests.rs::weight_follows_the_contract_formula` (unit)<br>`tests/swift/layout-fixtures.swift::testLayoutFixtures` (Swift host) |
| AK-CONTRACT-7 | `src/contract/model_tests.rs::path_data_follows_the_reference_grammar` (unit)<br>`tests/swift/layout-render.swift::testRenderPaths` (Swift host) |
| AK-CONTRACT-8 | `src/contract/limit_tests.rs::a_tree_is_at_most_8_levels_deep` (unit)<br>`src/contract/limit_tests.rs::each_region_has_its_node_and_button_limits` (unit) |
| AK-CONTRACT-9 | `src/contract/rule_tests.rs::rejects_each_reference_rule` (unit)<br>`src/contract/rule_tests.rs::a_bound_member_takes_what_its_literal_takes` (unit)<br>`src/contract/rule_tests.rs::rejects_a_bound_member_whose_value_does_not_fit` (unit)<br>`src/contract/model_tests.rs::bound_members_keep_their_wire_shape` (unit) |
| AK-CONTRACT-10 | `src/contract/rule_tests.rs::the_base_request_is_valid` (unit)<br>`src/contract/rule_tests.rs::rejects_each_request_and_value_rule` (unit)<br>`src/contract/rule_tests.rs::rejects_each_style_and_color_rule` (unit)<br>`src/contract/rule_tests.rs::accepts_the_limits_of_each_rule` (unit)<br>`src/contract/limit_tests.rs::typed_requests_meet_the_same_rules` (unit)<br>`src/contract/limit_tests.rs::an_update_checks_its_id_and_its_values_alone` (unit)<br>`src/contract/model_tests.rs::every_node_keeps_its_wire_shape` (unit)<br>`src/contract/model_tests.rs::every_style_member_keeps_its_wire_shape` (unit)<br>`src/contract/model_tests.rs::requests_and_records_keep_their_wire_shape` (unit) |
| AK-CONTRACT-11 | `tests/contract.rs::numbers_keep_their_value_when_read_from_json_text` (unit) |
| AK-CONTRACT-12 | `tests/contract.rs::every_fixture_gets_its_verdict_code_and_weight` (unit)<br>`tests/contract.rs::every_end_fixture_is_checked_against_its_start` (unit)<br>`tests/swift/layout-fixtures.swift::testLayoutFixtures` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeFixtures` (Swift host) |
| AK-CONTRACT-13 | `src/contract/model_tests.rs::a_record_carries_what_activitykit_knows_and_reads_past_older_members` (unit)<br>`tests/swift/layout-lifecycle.swift::testLayoutLifecycle` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-BRIDGE-1 | `tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-BRIDGE-2 | `tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-BRIDGE-3 | `tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeFromManyThreads` (Swift host)<br>`tests/swift/bridge-abi.swift::testBridgeAuthorizationAndImages` (Swift host) |
| AK-BRIDGE-4 | `src/bridge.rs::malformed_replies_fail_closed` (unit)<br>`src/bridge.rs::unwraps_success_and_keeps_the_swift_error_codes` (unit) |
| AK-BRIDGE-5 | `tests/swift/bridge-abi.swift::testBridgeEvents` (Swift host) |
| AK-BRIDGE-6 | `tests/swift/bridge-abi.swift::testBridgeUnsupported` (Swift host) |
| AK-BRIDGE-7 | `tests/swift/bridge-abi.swift::testBridgeLifecycle` (Swift host) |
| AK-BRIDGE-8 | `tests/swift/bridge-abi.swift::testBridge` (Swift host)<br>`tests/build/run.sh::check_ios` (build) |
| AK-BRIDGE-10 | `tests/swift/settings.swift::testSettings` (Swift host) |
| AK-BRIDGE-11 | `src/kit/tests.rs::a_call_the_bridge_never_answers_fails_after_the_call_wait` (unit)<br>`src/kit/tests.rs::the_call_wait_is_ten_seconds` (unit)<br>`src/kit/write_tests.rs::a_write_the_bridge_never_answers_fails_after_the_call_wait_and_frees_the_turn` (unit)<br>`src/kit/write_tests.rs::a_reply_that_comes_after_the_wait_changes_nothing_of_the_handle` (unit)<br>`src/kit/write_tests.rs::a_late_reply_does_not_undo_an_end` (unit)<br>`src/kit/write_tests.rs::a_late_reply_does_not_free_the_turn_of_the_write_in_flight` (unit)<br>`src/kit/write_tests.rs::a_dropped_reply_fails_its_write_and_passes_the_turn_on` (unit) |
| AK-BRIDGE-9 | `src/kit/tests.rs::dropping_a_future_does_not_cancel_its_request` (unit)<br>`src/kit/write_tests.rs::a_dropped_writes_reply_still_reaches_the_handle` (unit)<br>`src/kit/write_tests.rs::a_dropped_reply_fails_its_write_and_passes_the_turn_on` (unit)<br>`tests/ios-host/src/lib.rs::policies` (simulator)<br>`tests/ios-host/UITests/PolicyTests.swift::testDismissalsAndRelevance` (simulator) |
| AK-BUILD-1 | `tests/build/run.sh::check_ios` (build) |
| AK-BUILD-2 | `tests/build/run.sh::check_ios` (build) |
| AK-BUILD-3 | `tests/build/run.sh::check_ios` (build) |
| AK-BUILD-4 | `tests/build/run.sh::check_host` (build) |
| AK-BUILD-5 | `tests/build/run.sh::check_skip` (build) |
| AK-BUILD-6 | `tests/build/run.sh::check_ios` (build) |
| AK-WIDGET-1 | `tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testEveryNodeTypeDraws` (simulator) |
| AK-WIDGET-2 | `tests/swift/layout-lifecycle.swift::testLayoutWidgetPreflight` (Swift host) |
| AK-RENDER-1 | `tests/swift/layout-render.swift::testRenderContent` (Swift host) |
| AK-RENDER-2 | `tests/swift/layout-render.swift::testRenderContent` (Swift host) |
| AK-RENDER-3 | `tests/swift/layout-render.swift::testRenderContent` (Swift host)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-RENDER-4 | `tests/swift/layout-render.swift::testRenderContent` (Swift host) |
| AK-RENDER-5 | `tests/swift/layout-render.swift::testRenderContent` (Swift host)<br>`tests/swift/layout-custom.swift::testFontFamilyAndFileImages` (Swift host) |
| AK-RENDER-6 | `tests/swift/layout-render.swift::testRenderPaths` (Swift host) |
| AK-RENDER-7 | `tests/swift/layout-render.swift::testRenderContent` (Swift host) |
| AK-RENDER-8 | `tests/swift/layout-render.swift::testRenderContent` (Swift host) |
| AK-RENDER-9 | `tests/swift/layout-render.swift::testRenderContent` (Swift host) |
| AK-RENDER-10 | `tests/swift/layout-render.swift::testRenderContent` (Swift host)<br>`tests/ios-host/UITests/HostTests.swift::testLockScreenButtonReachesRust` (simulator) |
| AK-RENDER-11 | `tests/swift/layout-custom.swift::testCustomNodes` (Swift host) |
| AK-RENDER-12 | `tests/swift/layout-render.swift::testRenderContent` (Swift host) |
| AK-RENDER-13 | `tests/swift/layout-render.swift::testRenderStyles` (Swift host)<br>`tests/swift/layout-render.swift::testRenderBoundStyles` (Swift host) |
| AK-RENDER-14 | `tests/swift/layout-render.swift::testIslandDefaults` (Swift host) |
| AK-RENDER-15 | `tests/swift/layout-render.swift::testRenderStyles` (Swift host)<br>`tests/swift/layout-render.swift::testRenderBoundStyles` (Swift host) |
| AK-RENDER-16 | `tests/ios-host/src/lib.rs::every_node` (simulator)<br>`tests/ios-host/UITests/HostTests.swift::testEveryNodeTypeDraws` (simulator) |
