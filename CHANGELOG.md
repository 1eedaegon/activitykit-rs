# Changelog

## Unreleased

The first version: Live Activities for any Rust iOS app, split from tauri-plugin-live-activity 0.3.0 without Tauri.

- `ActivityKit`: `authorization`, `start` and `start_with` (key, stale date, relevance), `activities` after a relaunch,
  `events` (taps, lifecycle states, authorization) through `async-channel`, and `write_image`. Runtime-neutral futures;
  off iOS every call answers `Error::Unsupported`.
- `Activity`: `update` and `update_with` (alert, stale date, relevance) with the revision kept by the handle, `end`.
- The layout DSL of request contract v2 with builders: nodes, styles, bound style members, `fontFamily`, drawn images
  and custom views. `activitykit::contract` holds the requests, the records and the validator.
- The Swift layer of the plugin (validation, lifecycle, receipts, renderer) behind seven C functions instead of
  Tauri's plugin class; `build.rs` builds it into the Rust library for the device and both simulators.
- Swift package products for Xcode: `ActivityKitWidget` (`ActivityKitLayoutWidget()`), `ActivityKitIntent` and
  `ActivityKitViews`.
- The contract schema and fixtures, now kept here.
- A Dioxus example with an end-to-end test on the iOS Simulator.
