# Testing

Every behavior the crate promises is a requirement of [the specification](spec.md), and every requirement names the
tests that prove it. `tools/spec-coverage.sh` fails when a requirement has no test, a listed test does not exist or
does not name the requirement, or a test names an ID the specification lacks.

```sh
cargo test                      # the API against a fake bridge, the contract rules, every fixture, the docs, doctests
cargo llvm-cov --summary-only --fail-under-lines 80
sh tests/swift/run.sh           # the Swift models, lifecycle and C bridge on the Mac, every fixture, coverage ≥ 80 %
sh tests/build/run.sh           # what build.rs does for each target ("host": only the host and the type check)
tests/ios-host/run.sh           # end to end on a simulator of its own (ONLY=Class/test for one test)
sh tools/spec-coverage.sh       # the specification against the tests
sh tests/ci/run.sh              # which changed paths start which CI job
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
    end with final values; every node type drawn with its button; a start from the background, which ActivityKit
    refuses (`NotForeground`); `activities()` after a relaunch, whose handle continues the revision, and the same
    keyed start returning the running activity before and after it; redacted receipts that keep no values, and the
    values ActivityKit shows after a relaunch.
  - `PolicyTests`, which runs last because it leaves ended activities on the Lock Screen: the reply of a dropped update
    reaching the handle, an end with the system's default keeping its score and its place, an end's relevance, a
    dismissal at a time eight seconds ahead and at once for a past time.

## CI

`.github/workflows/ci.yml` decides from the changed paths what runs; `tests/ci/run.sh` checks those patterns. The
specification check, the path check and the docs test run on Linux for any change to code, tests or docs. Rust
changes run format, clippy (also for the iOS target, without Swift), the tests, coverage and the host build checks on
Linux, and the tests again on Rust 1.90, the crate's `rust-version`. The repository is private and a macOS minute costs
ten Linux minutes, so the macOS job runs only for changes that reach the Swift layer: the Swift package, every Rust
source and manifest, `build.rs`, the toolchain files, the templates, the Swift tests, the build checks and the test
host. It runs the Swift tests, the build checks for the device and both simulators, and `tests/ios-host/run.sh`.

`.github/workflows/publish.yml` runs on a `v*` tag: it checks the tag against the crate's version, that main's CI
passed for the tag's exact commit, and that the crate packages. It publishes nothing until `publish = false` leaves
`Cargo.toml` and the repository variable `CRATES_IO_PUBLISH` is `true`.

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

Not tested: a phone, iOS 16.2 to 17.1, a locked device with a passcode, ActivityKit's `stale` state (the simulator
did not report it), and what the specification lists as not proven by a test.
