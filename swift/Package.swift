// swift-tools-version:5.9
import PackageDescription

// The Swift half of the activitykit crate. build.rs builds `ActivityKitBridge` into the Rust library. An app links
// `ActivityKitWidget` to its widget extension and `ActivityKitIntent` to the app target; with custom views, it links
// `ActivityKitViews` to both.
let package = Package(
    name: "activitykit",
    platforms: [.iOS(.v15)],
    products: [
        // The C functions that Rust calls, with the lifecycle and the ActivityKit backend. Only build.rs builds it;
        // never link it in Xcode, the Rust library holds it already.
        .library(name: "ActivityKitBridge", type: .static, targets: ["ActivityKitBridge"]),
        // The widget extension: `ActivityKitLayoutWidget()`, the layout renderer and the button intent.
        .library(name: "ActivityKitWidget", targets: ["ActivityKitWidget"]),
        // The button intent alone, for the app target, where the system runs it.
        .library(name: "ActivityKitIntent", targets: ["ActivityKitIntent"]),
        // The registry of custom SwiftUI views, for the widget extension and the app.
        .library(name: "ActivityKitViews", targets: ["ActivityKitViews"])
    ],
    targets: [
        .target(name: "ActivityKitShared", path: "Sources/ActivityKitShared"),
        .target(name: "ActivityKitCore", dependencies: ["ActivityKitShared"], path: "Sources/ActivityKitCore"),
        .target(name: "ActivityKitUI", dependencies: ["ActivityKitShared"], path: "Sources/ActivityKitUI"),
        .target(name: "ActivityKitViews", path: "Sources/ActivityKitViews"),
        .target(name: "ActivityKitIntent", path: "Sources/ActivityKitIntent"),
        .target(name: "ActivityKitBridge", dependencies: ["ActivityKitShared", "ActivityKitCore"], path: "Sources/ActivityKitBridge"),
        .target(name: "ActivityKitWidget", dependencies: ["ActivityKitShared", "ActivityKitUI", "ActivityKitViews", "ActivityKitIntent"],
                path: "Sources/ActivityKitWidget")
    ],
    swiftLanguageVersions: [.v5]
)
