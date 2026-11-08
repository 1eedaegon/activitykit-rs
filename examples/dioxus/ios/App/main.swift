// The app's entry point: Rust takes over (src/lib.rs) and Dioxus runs UIApplicationMain. It is Swift, not Objective-C,
// because Xcode extracts the App Intents metadata of the linked ActivityKitIntent product only for a target that
// compiles Swift.
@_silgen_name("start_app")
func startApp()

startApp()
