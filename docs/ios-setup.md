# iOS setup

An app that uses activitykit has three parts: the Rust library, which holds activitykit's Swift bridge; the app
target in Xcode; and a widget extension, a Swift target, that draws the activity. The example's
[`ios/project.yml`](../examples/dioxus/ios/project.yml) is all of this in one XcodeGen file.

## What build.rs does

For an iOS target, the crate's build script runs SwiftPM on the `swift` package of this repository and links its
`ActivityKitBridge` product (the C functions, the lifecycle with its receipts, and the ActivityKit calls) into the Rust
library:

```text
xcrun swift build --package-path swift --product ActivityKitBridge --build-path $OUT_DIR/swift -c release|debug \
  --arch <host> --sdk <iOS SDK> -Xswiftc -sdk -Xswiftc <iOS SDK> \
  -Xswiftc -target -Xswiftc <arch>-apple-ios<version>[-simulator] -Xcc --target=<same>
```

| Rust target | Swift target | SDK |
| --- | --- | --- |
| `aarch64-apple-ios` | `arm64-apple-ios15.0` | iphoneos |
| `aarch64-apple-ios-sim` | `arm64-apple-ios15.0-simulator` | iphonesimulator |
| `x86_64-apple-ios` | `x86_64-apple-ios15.0-simulator` | iphonesimulator |

These are the flags of the `swift-rs` crate, with which Tauri builds its iOS plugins. `swift-rs` itself is not used:
it builds every target of a package, here also the SwiftUI renderer and the widget, which the app's library must not
contain, and it needs a static product named like the package. The version is `IPHONEOS_DEPLOYMENT_TARGET`, at least
15.0; set it to the app's deployment target so the linker does not warn about newer objects. The build is `debug`
when the Rust profile has `opt-level = 0`, `release` otherwise.

For a binary that rustc links, the script also adds the Swift runtime's search paths (`swift -print-target-info`) and
compiler-rt (`clang_rt.ios` or `clang_rt.iossim`, for `#available`). `ACTIVITYKIT_SKIP_SWIFT=1` skips the Swift build,
for `cargo check` or `clippy` of the iOS code on a machine without Xcode; nothing links then.

On every other target the script does nothing.

## The app target

Most Rust iOS apps build Rust as a static library (`crate-type = ["staticlib"]`) and link it from an Xcode app target
whose `main` calls into Rust, as Tauri and the example do. The app target then needs:

- **The library and its frameworks.** Link the `.a` by its path (`OTHER_LDFLAGS`; with `-l` the linker would prefer a
  dylib of the same name on a Mac), and the frameworks that `cargo rustc --crate-type staticlib -- --print
  native-static-libs` lists for your app. activitykit's Swift objects bring their own (ActivityKit, Foundation, UIKit,
  CryptoKit) through Swift's autolinking.
- **The Swift runtime's search paths**, since the library contains Swift objects that Xcode did not compile:

  ```yaml
  LIBRARY_SEARCH_PATHS: $(inherited) $(SDKROOT)/usr/lib/swift $(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)
  ```

  Xcode adds these paths by itself to a target that compiles Swift, which the app target does anyway for buttons
  (below), so the example sets nothing. They matter for an app target without Swift whose library holds Swift objects
  built below iOS 17, which link the toolchain's compatibility libraries. Checked with Xcode 26.3: such an app target
  failed to link (`swiftCompatibility56` not found) with the bridge built for iOS 15, and linked with these paths; the
  same library linked without them into the example, whose `main` is Swift; built for iOS 17 it linked either way.
  fremen's Tauri app sets the paths too.
- **`IPHONEOS_DEPLOYMENT_TARGET`** set to the app's deployment target while cargo builds, so the Swift bridge and any
  C code of other crates are built for it and the linker does not warn about newer objects.
- **`NSSupportsLiveActivities`** set to `YES` in the Info.plist.
- **The `ActivityKitIntent` product**, for buttons. The system runs the button's intent in the app process, so the app
  needs the intent's code and its App Intents metadata. Xcode 26 extracts that metadata from a linked package product,
  but only for a target that compiles Swift: an app whose `main` is Objective-C gets no metadata, and a tap does
  nothing. Give the app target at least one Swift file; the example's `main.swift` is three lines. Link no other
  product of the package to the app (except `ActivityKitViews`, below): the bridge's Swift code is in the Rust library
  already, and a second copy would duplicate its symbols. The app must not define its own `ActivityKitActionIntent`:
  Xcode refuses an intent that conflicts with one of a linked package.
- **The widget extension** as a dependency, embedded.

Start activities while the app is in the foreground.

## The widget extension

Add a Widget Extension target (iOS 16.1 or later), link the `ActivityKitWidget` product of the `swift` package (as a
local package, or from this repository), and replace its Swift files with
[`templates/ios/Widget.swift`](../templates/ios/Widget.swift):

```swift
import ActivityKitWidget
import SwiftUI
import WidgetKit

@main
struct Widgets: WidgetBundle {
    var body: some Widget { ActivityKitLayoutWidget() }
}
```

Its Info.plist ([`templates/ios/Widget-Info.plist`](../templates/ios/Widget-Info.plist)) sets `ActivityKitLayout` to
the integer `2`: before a start, the app checks that an embedded extension carries it, and answers
`CONFIGURATION_REQUIRED` otherwise. Give the extension an identifier under the app's and the same signing team. A
widget of your own can sit in the same bundle; `LayoutView` and the layout types come with `import ActivityKitWidget`
for one that draws the layout itself.

## Drawn images

`ActivityKit::write_image` needs an App Group that both targets have in `com.apple.security.application-groups`, named
in the extension's Info.plist under `ActivityKitAppGroup`. On a device, automatic signing registers the group once.

## Custom views

Copy [`templates/ios/CustomViews.swift`](../templates/ios/CustomViews.swift) into both targets and link the
`ActivityKitViews` product to both. The widget draws the views; the app reads which names have one and reports the
others in `degraded_features`. Keep the Objective-C name `ActivityKitCustomViews`.

## Fonts

A `font_family` must be a font that the widget extension bundles and lists under `UIAppFonts` in its Info.plist.

## Names that differ from tauri-plugin-live-activity

The Swift logic is the plugin's; only names that carried "Tauri" changed:

| Plugin | activitykit |
| --- | --- |
| `TauriLiveActivityLayout` (widget Info.plist) | `ActivityKitLayout` |
| `TauriLiveActivityAppGroup` | `ActivityKitAppGroup` |
| `tauri-live-activity/images`, `tauri-live-activity/receipts-v2.json` | `activitykit/images`, `activitykit/receipts-v2.json` |
| `TauriLiveActivityCustomViews` | `ActivityKitCustomViews` |
| `tauri.live-activity.action` (notification) | `activitykit.action` |
| `LiveActivityActionIntent` (template file in both targets) | `ActivityKitActionIntent` (package product) |
| modules `LiveActivityShared`, `LiveActivityCore`, `LiveActivityUI`, `LiveActivityPlugin` | `ActivityKitShared`, `ActivityKitCore`, `ActivityKitUI`, `ActivityKitBridge` |

The ActivityKit attributes type is still `LiveActivityLayoutAttributes`, with the same coding, so ActivityKit sees an
app's layout activities as the same kind after a move from the plugin.
