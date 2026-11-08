# Testing

Every behavior the crate promises is a requirement of [the specification](spec.md), and every requirement names the
tests that prove it. `tools/spec-coverage.sh` fails when a requirement has no test, a listed test does not exist or
does not name the requirement, or a test names an ID the specification lacks.

```sh
cargo test                      # the API against a fake bridge, the contract rules, every fixture, the docs, doctests
cargo llvm-cov --summary-only --fail-under-lines 80
sh tests/swift/run.sh           # the Swift models, lifecycle and C bridge on the Mac, every fixture, coverage ≥ 80 %
sh tests/build/run.sh           # what build.rs does for each target
tests/ios-host/run.sh           # end to end on a simulator of its own
sh tools/spec-coverage.sh       # the specification against the tests
```

- `src/kit/tests.rs` drives the whole API against `src/fake.rs`, a bridge that answers as the Swift layer does.
- `tests/contract.rs` and `tests/swift/` give every case of `tests/fixtures/layout-requests.json` its verdict, code and
  weight; the Swift side also sends each through the seven C functions, which it looks up by their symbols and calls
  from several threads. That is how Rust and Swift agree.
- `tests/build/run.sh` builds for the host (no Swift), checks the iOS code under `DOCS_RS` and `ACTIVITYKIT_SKIP_SWIFT`
  (no Swift), and for each installed iOS target builds the bridge and reads its platform, architecture, deployment
  target and C symbols. Without Xcode or an iOS target a check says "skip".
- `tests/ios-host` is an app without a UI framework: Rust scenarios (`src/lib.rs`) on a thread of their own, a SwiftUI
  shell that shows their report, and the template widget. `run.sh` builds it, creates a simulator, runs the UI test,
  copies the screenshots and the log to `tests/ios-host/output`, deletes the simulator and exits with the test's
  status. Its four tests: a start, a bound color turned red, Stop tapped on the Lock Screen and the event in Rust, an
  end with final values; every node type drawn on the Lock Screen with its button; a start from the background, which
  ActivityKit refuses (`NotForeground`); and `activities()` after a relaunch, whose handle continues the revision.

## CI

`.github/workflows/ci.yml` decides from the changed paths what runs. The specification check and the docs test run on
Linux for any change to code, tests or docs. Rust changes run format, clippy (also for the iOS target, without Swift),
the tests, coverage and the build checks on Linux. The repository is private and a macOS minute costs ten Linux
minutes, so the macOS job runs only when the Swift package, `build.rs`, the bridge's Rust side, the templates, the
Swift tests, the build checks or the test host change: the Swift tests, the build checks for the device and the
simulator, and `tests/ios-host/run.sh`.

`.github/workflows/publish.yml` runs on a `v*` tag: it checks the tag against the crate's version, that main's CI
passed for the tag's exact commit, and that the crate packages. It publishes nothing until `publish = false` leaves
`Cargo.toml` and the repository variable `CRATES_IO_PUBLISH` is `true`.

## Record

On 2026-11-08, on an Intel Mac with Xcode 26.3 and an iPhone 17 Pro simulator with iOS 26.3, `tests/ios-host/run.sh`
passed its four UI tests. On the Lock Screen the bound tone had turned the symbol, the status, the Stop button and the
level bar red; the tap reached Rust as `Event::Action` with the started handle, the activity ended with its final
values, and ActivityKit reported it dismissed. ActivityKit kept a relevance of 50 through an update that gave none. The
layout with every node type showed its symbol, text, timer, bar, circular gauge, path, divider and button, and its tap
reached Rust. A start from the background came back as `NotForeground` from ActivityKit's `visibility` error. After the
process ended, `activities()` found the other activity at revision 1, and its handle sent revision 2.

Not tested: a phone, iOS 16.2 to 17.1, a locked device with a passcode, and what the specification lists as not proven
by a test.
