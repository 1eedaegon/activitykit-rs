# Changelog

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
