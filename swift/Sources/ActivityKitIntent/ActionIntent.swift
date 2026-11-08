import AppIntents
import Foundation

/// The action of a layout `button` node. Link this product to the app target and to the widget extension (which gets
/// it through `ActivityKitWidget`). The widget builds the button with it; the system runs `perform()` in the app, so
/// the app needs the type in its binary and its App Intents metadata, which Xcode extracts from a linked package
/// product. It depends on nothing else of the package, so the app links it without a second copy of the Swift code
/// that the Rust library holds. The app must not define another `ActivityKitActionIntent`.
@available(iOS 17.0, *)
public struct ActivityKitActionIntent: LiveActivityIntent {
    public static let title: LocalizedStringResource = "Live Activity action"
    public static let isDiscoverable = false
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Activity") public var activityId: String
    @Parameter(title: "Action") public var actionId: String

    public init() {}
    public init(activityId: String, actionId: String) {
        self.activityId = activityId
        self.actionId = actionId
    }

    /// Runs in the app process and hands the tap to activitykit's bridge (`ActionPost`): every 100 ms for up to 5 s
    /// until the bridge acknowledges it, which it does once the app has taken the event.
    public func perform() async throws -> some IntentResult {
        try await ActionPost.post(activityId: activityId, actionId: actionId)
        return .result()
    }
}
