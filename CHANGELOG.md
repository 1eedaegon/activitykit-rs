# Changelog

## Unreleased

The first version: iOS Live Activities from Rust. Split out of tauri-plugin-live-activity 0.3.0.

- `ActivityKit`: `authorization`, `start` and `start_with` (key, stale date, relevance), `activities` after a relaunch,
  `events` (new activities, taps, lifecycle states with `Pending`, the whole authorization) through an `async-channel`
  receiver that is also a `Stream`, and `write_image`. Runtime-neutral futures; off iOS every call answers
  `Error::Unsupported`. iOS 16.2 or later.
- `Activity`: `update` and `update_with` (alert, stale date, relevance, timestamp) with the revision kept by the
  handle, `end` with final values, stale date, relevance and timestamp, and `state`, `values`, `revision`, `stale_at`,
  `relevance`. An update or end without a relevance keeps the score; a retry after `STALE_REVISION` happens only for
  newer content.
- `Error` with one variant per contract code, `NotForeground` for a start ActivityKit refuses outside the foreground,
  `UnsupportedFeature { feature, minimum_ios }` and `SystemLimit { scope }`.
- The layout DSL of request contract v2 with builders: nodes, styles, bound style members, `fontFamily`, drawn images
  and custom views. `activitykit::contract` holds the requests, the records and the validator.
- A Swift layer (validation, lifecycle, receipts, renderer) behind seven C functions; `build.rs` builds it into the
  Rust library for the device and both simulators.
- Swift package products for Xcode: `ActivityKitWidget` (`ActivityKitLayoutWidget()`), `ActivityKitIntent` and
  `ActivityKitViews`.
- The contract schema and fixtures, now kept here. Request contract v2 gains an optional `timestamp` in snapshots,
  optional final content in `end_layout`, `relevance` in records and the state `pending`; an `after` end takes any
  time.
- `docs/spec.md`, every requirement mapped to its tests, checked by `tools/spec-coverage.sh`.
- An iOS test host under `tests/ios-host`: plain Rust scenarios and a UI test that taps the Lock Screen button on a
  simulator, run by one script locally and in CI.
- CI on Linux and macOS, and a publish workflow that only validates until crates.io publishing is turned on.
