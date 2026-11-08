# activitykit with Dioxus

A Dioxus 0.7 app with a Live Activity: a recording status whose color is bound to a value, a level bar, and a Stop
button on the Lock Screen whose tap arrives in Rust as `Event::Action`.

```sh
./build.sh                       # the Rust library, the Xcode project, and an app build for the simulator
./e2e.sh                         # the same on a new simulator, with the UI test, then deletes the simulator
```

Both need XcodeGen and the iOS Rust target of the simulator (`x86_64-apple-ios` on an Intel Mac,
`aarch64-apple-ios-sim` on Apple silicon).

- `src/lib.rs`: the app. `start_app` is its entry point; launched with `-auto` it starts an activity, updates it two
  seconds later (the status turns red), and ends it when Stop is tapped.
- `ios/project.yml`: the Xcode project. The app target is `App/main.swift` linked against the Rust static library and
  the `ActivityKitIntent` product; the widget extension is `templates/ios/Widget.swift` linked against
  `ActivityKitWidget`.
- `ios/UITests/LockScreenTests.swift`: the end-to-end test.

Dioxus is the example because it builds fastest of the three on an Intel Mac: it draws in the system's WKWebView with
the wry and tao crates that Tauri uses, so it compiles no GPU stack (Bevy's wgpu and naga) and no UI compiler and
Skia (Slint). Its 282 crates built for the simulator in under two minutes.
