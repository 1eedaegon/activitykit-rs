# Testing

Every behavior the crate promises is a requirement of [the specification](spec.md), and every requirement names the
tests that prove it. `tools/spec-coverage.sh` fails when a requirement has no test, a listed test does not exist or
does not name the requirement, or a test names an ID the specification lacks.

```sh
cargo test                      # the API against a fake bridge, the contract rules, every fixture, the schema run by a validator, the docs, doctests
cargo llvm-cov --summary-only --fail-under-lines 80
sh tests/swift/run.sh           # the Swift models, lifecycle and C bridge on the Mac, every fixture, coverage ≥ 80 %
sh tests/build/run.sh           # what build.rs does for each target ("host": only the host and the type check)
tests/ios-host/run.sh           # end to end on a simulator of its own (ONLY=Class/test for one test)
sh tools/spec-coverage.sh       # the specification against the tests
sh tests/ci/run.sh              # which changed paths start which CI job
bash tests/release/run.sh       # the release tool, in repositories of its own
```

- `src/kit/tests.rs`, `src/kit/write_tests.rs` and `src/kit/event_tests.rs` drive the whole API against
  `src/fake.rs`, a bridge that answers as the Swift layer does, from another thread when a test asks for a delay. The
  fake joins those threads and fails the test when delivering a reply panicked.
- `tests/contract.rs` and `tests/swift/` give every case of `tests/fixtures/layout-requests.json` its verdict, code and
  weight; the Swift side also sends each through the C functions, which it looks up by their symbols and calls
  from several threads. That is how Rust and Swift agree. Both check that an error's message is constant text.
- The Swift coverage counts the code that runs on the Mac. The ActivityKit adapter, system, backend and observers are
  `#if os(iOS)` and compile to nothing there, so the gate does not see them; the simulator host runs them.
- `tests/build/run.sh` builds for the host (no Swift), checks the iOS code under `DOCS_RS` and `ACTIVITYKIT_SKIP_SWIFT`
  (no Swift), and for each iOS target builds the bridge and reads its platform, architecture, deployment target and C
  symbols. A check that cannot run here says "skip", and fails when `CI` is set.
- `tests/ios-host` is an app without a UI framework: Rust scenarios (`src/lib.rs`) on a thread of their own, a SwiftUI
  shell that shows their report, and the template widget. `run.sh` builds it, creates a simulator, runs the UI tests,
  copies the screenshots and the log to `tests/ios-host/output`, deletes the simulator and exits with the tests'
  status. In CI a failed UI test runs again, up to three times in all, because a shared runner's simulator sometimes
  loses its accessibility server or misses a Home press; each test that passed only on a retry is reported as a
  warning on the run. Locally there is no retry. The tests wait on what they check (a line of the report, an element, the app's state, a Darwin notification
  that the app posts when a scenario ends), not on fixed sleeps; the Lock Screen is pulled down from fixed points of
  the screen.
  - `HostTests`: a start, a bound color turned red, an update an hour older than the shown content that ActivityKit
    drops, Stop tapped on the Lock Screen and the event in Rust, a handler of 1 s that the tap's intent waits for, an
    end with final values; every node type drawn with its button; a path and a progress view found by label and bound
    value, a labelled stack as one element whose button a touch still reaches, and a link, the layout's URL and an
    `https` link each opening the host with its URL; a start scheduled 15 s ahead that is pending, holds its key,
    refuses an update and is active at its time with the content of its start, one ended while pending, an alert with
    a named sound, and a transient start; a toggle flipped on and off, each tap
    with the state asked for, and the switch following the app's update; a layout with a line for fresh and a line
    for stale content, whose Lock Screen changed from one to the other when its stale date, 90 s ahead, had passed,
    with no update and with the app ended, the list then saying `Stale`, and back after an update; a layout with a
    small region that starts with nothing degraded, and, in the host's preview app, what the widget's content view
    draws for the small family (the small region, or the compact parts of a layout without one) and for the medium
    one (the Lock Screen tree); a card and a box in it colored with two light and dark pairs, which screenshots
    show in colors of one appearance over several starts and when the appearance turns; a start from the background, which ActivityKit
    refuses (`NotForeground`); `activities()` after a relaunch, whose handle continues the revision, and the same
    keyed start returning the running activity before and after it; redacted receipts that keep no values, and the
    values ActivityKit shows after a relaunch; a start that asks for a push token, which ActivityKit refuses without
    the capability, and an update that does not come back as `Event::Updated`; a tap on the Lock Screen while the app is
    not running, which launches it, reaches Rust and is acknowledged after the handler.
  - `PlacementTests`: layouts of boxes in pure colors on a card of one color, found in screenshots of the Lock
    Screen and measured to the pixel: a box at each of a frame's nine alignments, at the card's edges, in its corners
    and in its middle, on a card whose color the widget draws, the system tints or nobody sets; padding of four
    lengths and of one; stacks, their alignments and a spacer; a card that grows and shrinks with one to five bars
    over updates, and the 160 points at which the system cuts it; a minimum height; boxes with a corner radius, a
    pill, and a box in a box; and, on a phone without a Dynamic Island (`DEVICE_TYPE`), the same card as the banner
    of an alert.
  - `PolicyTests`, which runs last because it leaves ended activities on the Lock Screen: the reply of a dropped update
    reaching the handle, an end with the system's default keeping its score and its place, an end's relevance, a
    dismissal at a time eight seconds ahead and at once for a past time.

### Older systems

`RUNTIME` points `run.sh` at another simulator runtime, by its `simctl` identifier, and the script picks the newest
iPhone Pro that the runtime knows:

```sh
RUNTIME=com.apple.CoreSimulator.SimRuntime.iOS-17-0 tests/ios-host/run.sh
```

The test host is built as an app with users on old systems is: the app for iOS 15.0, the oldest the crate builds for,
and the widget extension for 16.2. The same products run on every runtime. The host tells its scenarios which iOS
they run on, and a scenario and its UI test assert a feature from the iOS that has it and, below it, what the crate
does instead:

| From | What | Below it |
| --- | --- | --- |
| iOS 17.2 | a tap on a button or a toggle reaches Rust | their labels and nothing to tap; `Authorization::buttons` is false |
| iOS 17.2 | content older than the shown one is dropped | it is shown |
| iOS 18 | a transient start | `UnsupportedFeature` with `(18, 0)`, and no activity |
| iOS 18 | the small family in the preview app | the test is skipped |
| iOS 26 | a scheduled start | `UnsupportedFeature` with `(26, 0)`, and no activity |

A test that taps first makes sure that the system runs the app's intent at all (`HostCase.awaitIntents`): the App
Intents daemon of a new simulator starts with an empty database and reads the metadata of every system app before the
tested app's, and a tap until then runs nothing, for minutes on a slow Mac.

The runtimes worth a run are the oldest of each such iOS and the last one below it: 16.2, 17.0, 17.2, 18.0 and the
newest; 17.4 was added for a defect that only iOS 17 has (AK-RENDER-19). CI runs the newest only, since one run takes 20 minutes of a hosted macOS runner; the others were run by hand
(the record below), and what runs them from now on is an open question of
[the compatibility plan](prd-compatibility.md).

## CI

`.github/workflows/ci.yml` decides from the changed paths what runs; `tests/ci/run.sh` checks those patterns. The
specification check, the path check and the docs test run on Linux for any change to code, tests or docs. Rust
changes run format, clippy (also for the iOS target, without Swift), the tests, coverage and the host build checks on
Linux, and the tests again on Rust 1.90, the crate's `rust-version`. The macOS jobs are the slow ones, so they run only
for changes that reach the Swift layer: the Swift package, every Rust source and manifest, `build.rs`, the toolchain
files, the templates, the Swift tests, the build checks, the test host and `tests/ci/cache.sh`. One runs the Swift
tests and the build checks for the device and both simulators, the other `tests/ios-host/run.sh`.

### Releases

Versions follow the subjects of the commits on `main`, which are conventional commits:

| Subject | Release |
| --- | --- |
| `feat: …` | the next minor version |
| `fix: …`, `perf: …`, `refactor: …`, `docs: …`, `revert: …` | the next patch version |
| `test: …`, `ci: …`, `chore: …`, `build: …`, `style: …` | none |
| `!` after the type, or a `BREAKING CHANGE:` footer | a major version, only by hand |

`.github/workflows/auto-release.yml` runs when CI passed on `main`. `tools/release.sh plan` reads the commits since
the last tag; the highest of them decides. For a release the workflow writes the version commit (`chore: release
vX.Y.Z`: `Cargo.toml`, `Cargo.lock`, the test host's lock file, the README's dependency line for a new minor, and a
changelog section with the commits' subjects, above whatever was written by hand under `## Unreleased`), pushes it to
`main`, runs CI for that exact commit, tags it and starts `publish.yml`. A CI run in which no hosted runner took a
job ends as failed though nothing failed; the workflow runs such jobs again itself, up to three times, for `main`'s
run and for the version commit's (`tools/settle-ci.sh`, tested by `tests/release/settle.sh`). A commit that breaks the API with `!` or
a `BREAKING CHANGE:` footer stops the automatic release: run "Auto release" by hand with `major` checked. Before 1.0 a
change that breaks callers is a `feat`: the minor moves, which is how Cargo reads a 0.x version. A subject that is
not a conventional commit fails the plan; merge commits are passed over. `tests/release/run.sh` runs the tool in
repositories of its own, and the specification job runs it.

`.github/workflows/publish.yml` runs for a `v*` tag, pushed by hand or dispatched by the release workflow: it checks
the tag against the crate's version, that main's CI passed for the tag's exact commit, that the tests pass and the
crate packages, and creates the GitHub release with the changelog section as its notes. It publishes to crates.io
when it was dispatched with `publish` checked and the repository variable `CRATES_IO_PUBLISH` is `true`. The push of
the version commit needs `main` to accept pushes from GitHub Actions.

### Caches

- Every Rust job keeps its dependencies with `Swatinem/rust-cache`, keyed on the toolchain and the lock files. The build
  checks' job also keeps the crate's own outputs, among them the SwiftPM build of the bridge for each iOS target.
  `cargo-llvm-cov` comes as a binary from `taiki-e/install-action`.
- The simulator job caches the test host's Xcode products (`Build/Products` of its DerivedData, with the
  `.xctestrun`) under `simulator-products-v1-<system>-<arch>-xcode<version>-<build>-rust<toolchain>-<files>`.
  `<files>` is a hash of the tracked files under `src/`, `swift/`, `templates/`, `contracts/` and `tests/ios-host/`,
  `build.rs`, the manifests and the toolchain files. On that exact key `run.sh` (given it as `BUILD_KEY`) skips cargo
  and `build-for-testing` and tests the cached products through the project's scheme (XcodeGen takes under a second);
  when any of them is missing it builds. Other inputs build with the Rust dependencies from the cache, and Xcode
  builds from scratch: checkout gives every file a new modification time, so cargo recompiles the crate and the host
  and reruns `build.rs`, and Xcode would recompile every Swift source anyway; an incremental Xcode build over restored
  intermediates also made an app whose Lock Screen taps never reached it.
- A suite that passed is not run again for the same inputs: the same files, Xcode, runner image (`ImageOS`,
  `ImageVersion`), Rust and, for the simulator, the runtime (`tests/ci/cache.sh keys`). After a full pass the job
  uploads a record, an artifact named `passed-<suite>-<hash>` that keeps 90 days; a later run that finds it skips the
  suite, stays green, and names the run that passed it, with a warning for each test that passed there only on a
  retry. The record is an artifact rather than a cache because a push to main cannot read a pull request's caches, so
  the push that merges a pull request finds the pull request's pass. Only runs of this repository's `ci.yml` count.
  This covers the Swift tests, the build checks and the simulator suite.

To run everything from scratch, start the workflow by hand with `fresh` checked: it ignores every cache and record.
`retest` runs the suites again but keeps the build caches.

## Record

On 2026-11-08, on an Intel Mac with Xcode 26.3 and an iPhone 17 Pro simulator with iOS 26.3, `tests/ios-host/run.sh`
passed its UI tests. On the Lock Screen the bound tone had turned the symbol, the status, the Stop button and the level
bar red, and an update an hour older than the shown content did not show; the tap reached Rust as `Event::Action`
with the started handle, the activity ended with its final values, and ActivityKit reported it dismissed. ActivityKit
kept a relevance of 50 through an update and an end that gave none, and took 70 from an end that gave it. An ended
activity with the system's default policy was still listed 5 seconds later; one ended `after` a time eight seconds
ahead was dismissed at that time, and one ended `after` a past time within 0.1 s. The layout with every node type
showed its symbol, text, timer, bar, circular gauge, path, divider and button, and its tap reached Rust. A start from
the background came back as `NotForeground` from ActivityKit's `visibility` error. After the process ended,
`activities()` found the other activity at revision 1, and its handle sent revision 2.

On 2026-11-19, on the same Mac, the suite ran on new simulators of older systems for the first time, each the newest
iPhone Pro its runtime knows:

| iOS | Of 16 tests | What it showed |
| --- | --- | --- |
| 16.2 | 13 passed, 3 skipped | Buttons and toggles as their labels, `buttons` false, older content shown, a scheduled and a transient start refused with their floors |
| 17.0.1 | 13 passed, 3 skipped | The same. Before the widget drew labels there, five tests failed: a button was drawn and its tap ran nothing |
| 17.2 | 14 passed, 1 failed, 1 skipped | A button's tap in Rust, older content dropped; the toggle's tap did not arrive (AK-RENDER-19, not yet fixed in that run) |
| 18.0 | 12 passed, 3 failed, 1 skipped | The small family drawn, a transient start taken; the first three tests of a tap failed while the system had not read the app's intents, which the tests now wait for |
| 26.3 | 14 passed, 1 failed, 1 skipped | The first activity of the new simulator was not drawn within 45 s; the wait is 120 s now |

With the two fixes that those runs led to (AK-RENDER-10, AK-RENDER-19), the wait for the app's intents and the
placement tests, the suite of 23 tests then ran again on a new simulator of each:

| iOS | Phone | Of 23 tests |
| --- | --- | --- |
| 16.2 | iPhone 14 Pro | 19 passed, 4 skipped (two tests of a tap, the small family, the banner) |
| 17.0.1 | iPhone 15 Pro | 19 passed, 4 skipped (the same) |
| 17.2 | iPhone 15 Pro | 20 passed, 3 skipped, in two runs: four placement tests first measured a patch of that system's cyan wallpaper as part of a cyan box, and passed once a box was the largest patch of its color |
| 17.4 | iPhone 15 Pro | 20 passed, 3 skipped (older content shown, the small family, the banner) |
| 18.0 | iPhone 16 Pro | 21 passed, 2 skipped, in two runs: the placement test of the shapes first counted a square box's pixels, of which a row was mixed with the card's color, and passed once it read the box's four corners |
| 26.3 | iPhone 17 Pro | 21 passed, 2 skipped (older content shown, the banner) |

On iOS 17.2 and 17.4 the toggle under a text was tapped, which it had not been before AK-RENDER-19's fix. On iOS
18.0 the system ran the app's intent at the seventh tap of the wait, twenty seconds apart, and every tap after it.

What the placement tests measured was the same on every runtime but for two things. The card was 148 points high
for a layout of 148; of a box of 44 points in a corner 93 % showed; with one to five bars of 40 points one activity's
card was 40, 80, 120, 160 and 160 points high, the last without the upper half of its first bar and the lower half
of its last; a card whose frame takes all the height it can get was 64 points high. What differed: the card was 14
points from the screen's sides on the Pro phones from iOS 17.0 and 10 points on iOS 16.2, and 10 points on an iPhone
SE (3rd generation) with iOS 26.3; and a hex color as the system's tint read as itself up to iOS 18.0 and as (251,
251, 24) for `#FFFF00` on iOS 26.3. On the iPhone SE with iOS 26.3 the banner of an alert was the same card, 8
points below the top of the screen, with its nine boxes in the same places; one test failed there for a start that
answered `NATIVE_ERROR` on the loaded Mac, after the nine boxes of its first card had been found in their places.

Not tested: a phone, iOS 16.0, 16.1 and 17.1, a locked device with a passcode, ActivityKit's `stale` state as an event (the simulator
reported it in its list, in the stale scenario, and not within half a minute of a nearer stale date), and what the specification lists as not proven by a test.
