# PRD: compatibility

Status: phases 1 to 3 are built (see "Rollout"); "Where it stands" has what was measured. It follows the
compatibility plan of `liveupdate-rs` (its `docs/design/compatibility`), which asks the same three questions of an
AAR and an Android version, and it keeps the crate's Rust version as it is.

## Problem

Four parts meet where an activity is shown: the crate with its bridge in the app, the widget extension that the app
builds from the Swift package, the iOS of the device, and often a server that builds push payloads with the crate.
Each changes on its own, and each change can break one of the others.

**An older iOS.** The crate builds for an app from iOS 15.0. Its bridge starts an activity from iOS 16.2, one release
above ActivityKit's own first, 16.1. What a later iOS added is behind a check of the version: a button's and a
toggle's intent, a timestamp of the content and push-to-start (17.2), a channel and the small activity family (18), a
scheduled start and CarPlay (26).

- Until 2026-11-19 the simulator suite had run on one system, iOS 26.3. Every branch for an older iOS was read and
  never run. The two defects that week both sat where a value crosses into the system and no test crossed with it.
- Its first run on iOS 17.0 found a third of that kind: a button was drawn, and a tap on it ran nothing. The floor of
  buttons had been read from the SDK (`LiveActivityIntent`, iOS 17.0); what decides it is the App Intents metadata
  that Xcode writes into the app, which begins the intent with iOS 17.2 (see "Where it stands").
- An app tells what the device can do from `Authorization`: `supported`, `enabled`, `buttons`, `frequent_pushes`.
  For a scheduled start, push-to-start, a channel or the small family it has to try and read the error.

**An app's crate and its widget of two versions; a server's crate and an installed app.** The app links the widget
extension against the Swift package "as a local package, or from this repository", so the package can be of another
version than the crate. A server is updated in a day; the app on a phone stays for months.

- The widget reads a layout strictly (`LayoutReader`): one member it does not know and the whole layout is refused,
  and the activity is drawn empty. Contract v2 has grown that way with every minor release: `accessibility`,
  `transition`, `privacy`, `link`, `toggle`, `ifStale`, `small`.
- The check before a start asks only that an embedded widget's Info.plist says `ActivityKitLayout` 2. It does not
  say which members that widget knows.
- A content state that a later crate built for a push is read by the same strict reader in an earlier app.
- The app keeps receipts on disk. If they cannot be read, every call that lists activities fails
  (`NATIVE_ERROR`). Whether a receipt of another version can be read is not known.

**The Rust API.** A new member breaks every struct literal that names all members, and a new variant every `match`
without a `_` arm. Six of 33 public enums are `#[non_exhaustive]` (`State`, `Error`, `LimitScope`, `Event`,
`Receipts`, `Push`), and 19 structs have nothing but public members. 0.5.0 and 0.6.0 each added a member to `Node`
or `Layout`.

## Goal

A newer crate, a newer widget, a newer server and an older iOS each keep the other parts working, with less shown
where something is not known, and code written against this version compiles against the next.

## Required capabilities

An older iOS:

- The simulator suite runs on the oldest runtime of each floor and on the last one below it (iOS 16.2, 17.0, 17.2,
  17.4, 18.0, and 18.0 with watchOS 11.0 by hand) as on the newest. A test says from which iOS it holds; below that it
  asserts what the crate does instead.
- A floor is what was run on that system, not the availability the SDK states for a type.
- An app built for iOS 15.0 starts on a system that has no ActivityKit, and the crate answers `Unsupported` there.
- The bridge starts, updates and ends an activity on iOS 16.1, with what 16.1 has: no stale date and no relevance.
- The crate says, feature by feature, what the device does: a capability for each thing that has a floor of its own.
  A request that needs one the device lacks is refused before ActivityKit is asked.
- Below its floor a part of a layout is the nearest thing the system has, and never a wrong one: a button and a
  toggle are their labels; the small family is the island's compact parts; a scheduled start is refused, since a
  start time that is ignored starts the activity now.

Parts of two versions:

- The widget draws a layout that has members it does not know, without them, and a node of a type it does not know
  as nothing. What it knows, it checks as before.
- The widget reads a content state that has members it does not know.
- A request from the app is read as strictly as before, in Rust and in the bridge: a member that is not known there
  is a mistake of the caller, and is refused where it was written.
- A receipt that cannot be read costs that receipt, not the list.
- A member that an activity depends on comes with a capability of the widget, read from the embedded extension as
  the small family is today, and the lifecycle refuses or reports the request where the widget lacks it.

The Rust API:

- Every public enum is `#[non_exhaustive]`.
- Every struct a caller builds has a constructor that takes what is required, to build on.

## Options considered

| Option | Why not |
| --- | --- |
| A deployment target below iOS 15 | Swift concurrency is part of the system from 15. Below it an app must embed the back-deployment library, which is another path through the build that `build.rs` links |
| Live Activities below iOS 16.1 | ActivityKit is not there |
| A button below iOS 17 as a link that opens the app | An intent runs without opening the app; a link does not. A layout that wants a link there can write one |
| A version number of the widget in its Info.plist | The capabilities say, feature by feature, what a widget draws. A number would say it twice, and somebody must keep it true by hand |
| The crate leaves out what the widget does not know | The document that is started is the one that is stored, compared with an update and sent in a push. Leaving a member out for one widget changes all of them |
| The widget refuses an unknown member, as today | Nothing is shown. A member that is not shown is the smaller loss |
| Every runtime in CI on every pull request | The hosted macOS runners are short, and a run on one runtime takes 20 minutes. The old runtimes run on a schedule and by hand |
| A lower Rust version | The owner keeps the crate's Rust version; it goes up, not down |
| Buttons on iOS 17.0 and 17.1: the intent declared from iOS 16.0, its `LiveActivityIntent` conformance from 17.0 | Xcode then writes the intent as one of iOS 16.0, with the name an older system finds it by. iOS 16 would list it in Shortcuts as an action of the app, since `isDiscoverable` is of iOS 17.0, and more phones end at iOS 16 than stay on 17.0 or 17.1. Read, not run |
| Buttons on iOS 17.0 and 17.1: `ENABLE_APPINTENTS_DEPLOYMENT_AWARE_PROCESSING = NO` | Built so, a tap arrived on the iOS 17.0 simulator. But a project's build settings do not reach a package's targets, only `xcodebuild`'s command line does, and what an intent written that way does on iOS 16 is not known |

## Success criteria

- The simulator tests pass on iOS 26.3 and on 16.2, 17.0, 17.2, 17.4 and 18.0, but for those that assert a later
  iOS, and each of those asserts what happens below it.
- A widget of this version draws a layout of a later crate, and an app of this version takes a push of a later
  server.
- Code that builds its requests on the constructors and matches with a `_` arm compiles when a member or a variant
  is added.
- Tests are written and seen failing first.

## Not goals

- A widget up to 0.7.0. It refuses what it does not know, and stays as it is.
- An unknown value of a member that is known, a font, an alignment, a transition, a length word or an image source:
  it is refused as before, since nothing says what to show instead.
- A lower Rust version, and a deployment target below iOS 15.
- A watch app, and anything on watchOS or CarPlay beyond the small family the iPhone draws.

## Where it stands

Measured on 2026-11-19, on an Intel Mac with Xcode 26.3. The test host is built for iOS 15.0 (its widget for 16.2),
and `tests/ios-host/run.sh` takes `RUNTIME` and picks a phone that the runtime knows.

**The suite, 16 tests, on a new simulator of each runtime:**

| iOS | Passed | Failed | Skipped | What it showed |
| --- | --- | --- | --- | --- |
| 16.2 | 13 | 0 | 3 (two tests of a tap, the small family) | Buttons and toggles as their labels; older content shown; a scheduled and a transient start refused with their floors |
| 17.0.1 | 13 | 0 | 3 (the same) | The same, after the fix below; before it, five tests failed: a button was drawn and its tap ran nothing |
| 17.2 | 14 | 1 | 1 (the small family) | A button's tap arrives, older content is dropped. A toggle's tap does not arrive: see below |
| 18.0 | 12 | 3 | 1 (older content shown) | The small family is drawn; a transient start is taken. The first three tests of a tap failed and the two later ones passed: see below |
| 26.3 | 14 | 1 | 1 (the same) | As in CI, but that the first activity of the new simulator was not drawn within 45 s, in two runs of two; the wait is now 120 s |

These are the runs that found what follows, before any of it was fixed but the labels on iOS 17.0. With the fixes
the suite, by then 23 tests, ran again on 16.2, 17.0, 17.2, 17.4, 18.0 and 26.3: docs/testing.md has that record.

**What the runs found:**

- **Buttons were dead on iOS 17.0** (and, by the same metadata, 17.1). Xcode's `appintentsmetadataprocessor` writes an
  intent that is newer than the deployment target of its module into `Metadata.appintents/extract.actionsdata` with
  an empty `mangledTypeName`, and an `introducedVersion` of 17.0 as 17.2 ("deployment-aware processing", on by
  default). The package is built for iOS 15, so `ActivityKitActionIntent` got that form whatever the app's own
  deployment target is: the app's metadata takes the package's as it is. On the iOS 17.0 simulator the widget
  daemon logged the action as started and executed, and `perform()` ran in no process. Built with that processing
  off, the same test passed there. The fix moves the floor of buttons and toggles to iOS 17.2: the widget draws
  their labels below it and `Authorization::buttons` is false.
- **On iOS 17 a control of a layout narrower than the card could not be tapped.** A toggle's tap did not arrive on
  iOS 17.2, in four runs of four, while buttons' did; on iOS 17.4 a button's did not arrive either, in eleven taps
  of eleven. Each time the widget daemon took the touch as a tap on the activity ("Widget tapped, no url") and
  opened the app. What the layouts that failed had in common was their width: a text above the control, narrower
  than the card, where the layouts that were tapped filled it. With the widget taking the card's whole width for
  the content, the same layouts were tapped on iOS 17.4 at the first tap. The widget now does that on the Lock
  Screen; iOS 18.0 and 26.3 found the controls either way.
- **A new simulator knows no intent of a new app for minutes.** The App Intents daemon starts with an empty database
  and reads the metadata of every system app before the tested app's; until then a tap fails with "There is no
  metadata for ActivityKitActionIntent". On the iOS 18.0 simulator that took more than four minutes after the
  install. It is the simulator's first boot and no defect of the crate, and it is why the first tests of a tap
  fail on a slow Mac; the tests have to tap until the intent runs.
- **The host's Rust code was built for iOS 17.0 while its app was built for 15.0.** Cargo does not rebuild what it
  built for another `IPHONEOS_DEPLOYMENT_TARGET`: the variable is none of its inputs. The linker said so 365 times
  and linked; `run.sh` now builds the Rust side anew when the deployment target is another than last time.
- Built for iOS 15.0, the bridge's 120 references to ActivityKit's symbols are all weak (`nm -m` on the objects of
  `libActivityKitBridge.a`), which is what makes a linker load the framework weakly. On 2026-11-20 the test host,
  built for iOS 15.0, ran on the iOS 16.0 simulator, which has no ActivityKit: the authorization said nothing is
  supported and a start and the list answered `Unsupported` (`testOlderSystemsAnswerUnsupported`). The widget
  extension, built for 16.2, did not keep the app from installing.
- iOS 17.1 cannot be run here: Xcode 26.3 offers no simulator runtime of it.

**Parts of two versions (phase 3, 2026-11-20).** The reader of the contract's objects is strict only where a decoder
asks for it (`JSONDecoder.layoutRequests()`), which the bridge does for the app's requests. ActivityKit decodes the
attributes and the content state with a decoder of its own, in the widget and in the app, so the reader there is the
lenient one: an unknown member is passed over and an unknown node type is drawn as nothing (AK-COMPAT-1, AK-COMPAT-2).
The receipts are read entry by entry (AK-COMPAT-3). The Swift host tests prove it with JSONDecoder, which is what the
widget's decoding comes to; no simulator test starts an activity of a later version, since the app's own bridge
refuses one. No member of the widget needs a capability yet (the first open question): every member added so far
changes what is shown, and only `small` changes where, which `small_family` already says.

## Rollout

| Phase | What | Release |
| --- | --- | --- |
| 1 | The suite on iOS 16.2, 17.0, 17.2, 17.4 and 18.0: tests state their floor; what fails is fixed | patch, per fix: 0.6.6 |
| 2 | Capabilities: what the device and the embedded widget do (`Authorization`'s members, AK-AUTH-8), and a refusal before ActivityKit is asked (as before, `UnsupportedFeature`) | minor: 0.7.0 |
| 3 | The widget and the content state read what they do not know; receipts one by one | minor: built for 0.8.0 |
| 4 | iOS 16.1 in the bridge | minor |
| 5 | Open enums and constructors: one breaking release, so that later ones are not | minor (0.x), with `!` |

## Open questions

- Which of the widget's members an activity depends on, so that they need a capability and not only a lenient read.
  `small` already has one. A candidate: none of the others changes what happens, only what is shown.
- Whether the schedule that runs the old runtimes is a workflow of this repository or a script somebody runs before
  a release.
