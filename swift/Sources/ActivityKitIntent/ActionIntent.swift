import AppIntents
import Foundation

/// The action of a layout `button` or `toggle` node. Link this product to the app target and to the widget extension (which gets
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
    /// Whether the action is a toggle's. Only then does the tap ask for a state: a button's intent sets neither value,
    /// and the system hands both to the app as false.
    @Parameter(title: "Toggle", default: false) public var isToggle: Bool
    /// The state the person asked a toggle for. A button's says nothing.
    @Parameter(title: "On", default: false) public var isOn: Bool

    public init() {}
    /// `isOn` is the state a toggle is asked for; a button gives none.
    public init(activityId: String, actionId: String, isOn: Bool? = nil) {
        self.activityId = activityId
        self.actionId = actionId
        self.isToggle = isOn != nil
        self.isOn = isOn ?? false
    }

    /// Runs in the app process and hands the tap to activitykit's bridge (`ActionPost`): every 100 ms for up to 5 s
    /// until the bridge acknowledges it, which it does once the app has taken the event.
    public func perform() async throws -> some IntentResult {
        try await ActionPost.post(activityId: activityId, actionId: actionId, isOn: ActionPost.state(isToggle: isToggle, isOn: isOn))
        return .result()
    }
}
