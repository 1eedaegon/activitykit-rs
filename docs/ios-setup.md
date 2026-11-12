# iOS setup

An app that uses activitykit has three parts: the Rust library, which holds activitykit's Swift bridge; the app
target in Xcode; and a widget extension, a Swift target, that draws the activity. The test host's
[`project.yml`](../tests/ios-host/project.yml) is all of this in one XcodeGen file.

## What build.rs does

For an iOS target, the crate's build script runs SwiftPM on the `swift` package of this repository and links its
`ActivityKitBridge` product (the C functions, the lifecycle with its receipts, and the ActivityKit calls) into the Rust
library:

```text
xcrun swift build --package-path swift --product ActivityKitBridge --build-path $OUT_DIR/swift -c release|debug \
  --arch <host> --sdk <iOS SDK> -Xswiftc -sdk -Xswiftc <iOS SDK> \
  -Xswiftc -target -Xswiftc <arch>-apple-ios<version>[-simulator] -Xcc --target=<same>
```

The crate needs iOS 16.2 at run time (iPadOS 17 on an iPad); below it every call answers `Error::Unsupported`. The
Swift code is built for iOS 15.0 or later so that apps with a lower deployment target still link.

| Rust target | Swift target | SDK |
| --- | --- | --- |
| `aarch64-apple-ios` | `arm64-apple-ios15.0` | iphoneos |
| `aarch64-apple-ios-sim` | `arm64-apple-ios15.0-simulator` | iphonesimulator |
| `x86_64-apple-ios` | `x86_64-apple-ios15.0-simulator` | iphonesimulator |

These are the flags SwiftPM needs to build for iOS, the same the `swift-rs` crate passes. `swift-rs` itself is not used:
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
whose `main` calls into Rust; an app whose UI framework generates an Xcode project works the same way, and the widget
extension and the settings below go into that project. The app target needs:

- **The library and its frameworks.** Link the `.a` by its path (`OTHER_LDFLAGS`; with `-l` the linker would prefer a
  dylib of the same name on a Mac), and the frameworks that `cargo rustc --crate-type staticlib -- --print
  native-static-libs` lists for your app. activitykit's Swift objects bring their own (ActivityKit, Foundation, UIKit,
  CryptoKit) through Swift's autolinking.
- **The Swift runtime's search paths**, since the library contains Swift objects that Xcode did not compile:

  ```yaml
  LIBRARY_SEARCH_PATHS: $(inherited) $(SDKROOT)/usr/lib/swift $(TOOLCHAIN_DIR)/usr/lib/swift/$(PLATFORM_NAME)
  ```

  Xcode adds these paths by itself to a target that compiles Swift, which the app target does anyway for buttons
  (below), so the test host sets nothing. They matter for an app target without Swift whose library holds Swift objects
  built below iOS 17, which link the toolchain's compatibility libraries. Checked with Xcode 26.3: such an app target
  failed to link (`swiftCompatibility56` not found) with the bridge built for iOS 15, and linked with these paths; the
  same library linked without them into an app target whose `main` is Swift; built for iOS 17 it linked either way.
- **`IPHONEOS_DEPLOYMENT_TARGET`** set to the app's deployment target while cargo builds, so the Swift bridge and any
  C code of other crates are built for it and the linker does not warn about newer objects.
- **`NSSupportsLiveActivities`** set to `YES` in the Info.plist.
- **The `ActivityKitIntent` product**, for buttons. The system runs the button's intent in the app process, so the app
  needs the intent's code and its App Intents metadata. Xcode 26 extracts that metadata from a linked package product,
  but only for a target that compiles Swift: an app whose `main` is Objective-C gets no metadata, and a tap does
  nothing. Give the app target at least one Swift file; a `main.swift` that calls the Rust entry point is three lines. Link no other
  product of the package to the app (except `ActivityKitViews`, below): the bridge's Swift code is in the Rust library
  already, and a second copy would duplicate its symbols. The app must not define its own `ActivityKitActionIntent`:
  Xcode refuses an intent that conflicts with one of a linked package.
- **The widget extension** as a dependency, embedded.

Start activities while the app is in the foreground.

### Receiving a link's URL

A [`link` node or the layout's URL](usage.md#links) opens the app with that URL. The crate has no part in that: the
app receives it like any URL, so register nothing for it in Info.plist unless other apps should open the scheme too.

```swift
@main
struct Recorder: App {
    var body: some Scene {
        WindowGroup {
            ContentView().onOpenURL { url in
                // Validate before acting: a pushed layout carries a server's URL.
                route(url)
            }
        }
    }
}
```

In UIKit the URL comes to `scene(_:openURLContexts:)`, or to `scene(_:willConnectTo:options:)` when the tap launched
the app.

## Pushes

- **Push Notifications** capability on the app target (`aps-environment` in the entitlements), for push tokens,
  push-to-start and channels. Without it ActivityKit refuses a start that asks for a token
  (`Error::ConfigurationRequired`), as it does in the simulator.
- **`NSSupportsLiveActivitiesFrequentUpdates`** set to `YES` in the Info.plist, for frequent pushes; the person can
  turn them off in Settings, which `Authorization::frequent_pushes` reports.
- **Broadcast capability** under Push Notifications at developer.apple.com, for channels (iOS 18); Xcode cannot set it.
- Make the kit early at launch (`ActivityKit::new()` or `builder().build()`), before the app waits for anything: a
  tap, a push-to-start or a push that wakes the app in the background reaches it only once the kit exists.

## The widget extension

Add a Widget Extension target (iOS 16.2 or later), link the `ActivityKitWidget` product of the `swift` package (as a
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
