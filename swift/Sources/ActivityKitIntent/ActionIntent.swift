import AppIntents
import Foundation

/// The action of a layout `button` or `toggle` node. Link this product to the app target and to the widget extension (which gets
/// it through `ActivityKitWidget`). The widget builds the button with it; the system runs `perform()` in the app, so
/// the app needs the type in its binary and its App Intents metadata, which Xcode extracts from a linked package
/// product. It depends on nothing else of the package, so the app links it without a second copy of the Swift code
/// that the Rust library holds. The app must not define another `ActivityKitActionIntent`.
///
/// From iOS 17.2, though `LiveActivityIntent` is of iOS 17.0: Xcode writes an intent that is newer than the iOS its
/// module is built for (this package: 15) into the app's App Intents metadata as one that begins with iOS 17.2, and
/// without the name by which an older system finds the type. On iOS 17.0 and 17.1 a tap then runs nothing, in the app
/// or in the widget. The widget draws a button there as its label, and `Authorization.buttons` is false.
@available(iOS 17.2, *)
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
    /// The activity's key, which stays with the tap when ActivityKit no longer lists the activity. Empty from a widget
    /// that does not give it.
    @Parameter(title: "Key", default: "") public var activityKey: String
    /// The revision of the content shown when the button was drawn; -1 from a widget that does not give it.
    @Parameter(title: "Revision", default: -1) public var revision: Int

    public init() {}
    /// `isOn` is the state a toggle is asked for; a button gives none. `activityKey` and `revision` say what was shown.
    public init(activityId: String, actionId: String, isOn: Bool? = nil, activityKey: String = "", revision: Int64? = nil) {
        self.activityId = activityId
        self.actionId = actionId
        self.isToggle = isOn != nil
        self.isOn = isOn ?? false
        self.activityKey = activityKey
        self.revision = revision.map { Int($0) } ?? -1
    }

    /// Runs in the app process and hands the tap to activitykit's bridge (`ActionPost`): every 100 ms for up to 5 s
    /// until the bridge acknowledges it, which it does once the app has taken the event. A tap the app does not take
    /// at once is kept on disk until it does.
    public func perform() async throws -> some IntentResult {
        let tap = ActionTap(activityId: activityId, actionId: actionId, isOn: ActionPost.state(isToggle: isToggle, isOn: isOn),
                            activityKey: activityKey.isEmpty ? nil : activityKey, revision: revision < 0 ? nil : Int64(revision))
        try await ActionPost.post(tap)
        return .result()
    }
}
