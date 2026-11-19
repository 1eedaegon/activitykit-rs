import Foundation

/// How the intent of a button or a toggle hands its tap to activitykit's bridge in the app process: it posts the tap with an
/// acknowledgement every `interval` until the bridge acknowledges it, at most `attempts` times (5 s). The bridge
/// acknowledges once the app has taken the event, so the wait keeps an app that the system launched for the tap running.
/// A tap that the first `keepAfter` posts do not get acknowledged is also kept on disk (`ActionTapKeeper`), so that it
/// reaches the app later when the app does not take it within the 5 s, or when the system ends the app first.
/// Only Foundation, so that the host tests run it.
public enum ActionPost {
    /// The notification that `ActionRelay` observes.
    public static let notification = Notification.Name("io.github.1eedaegon.activitykit.action")
    public static let attempts = 50
    /// Between two posts, in nanoseconds.
    public static let interval: UInt64 = 100_000_000
    /// The posts after which a tap that is not acknowledged is kept: 200 ms. An app that runs takes a tap at the first
    /// post, and writes nothing.
    public static let keepAfter = 2

    /// The state a tap asks for, from the two values the intent carries: a toggle's tap says that it is one and which
    /// state it asks for, and any other tap asks for none. The intent cannot carry one optional value for this: the
    /// system hands the app a value that was never set as false, and a button's tap would ask to switch off.
    public static func state(isToggle: Bool, isOn: Bool) -> Bool? { isToggle ? isOn : nil }

    /// Posts the tap until it is acknowledged or the attempts run out, and says whether it was acknowledged. A tap that
    /// is not acknowledged after `keepAfter` posts is kept in `folder` as well, when there is one: the bridge hands it
    /// to the app when the app registers its handler, in this launch or a later one, and removes the file then.
    @discardableResult
    public static func post(_ tap: ActionTap, center: NotificationCenter = .default, keepingIn folder: URL? = ActionTapKeeper.folder,
                            attempts: Int = attempts, interval: UInt64 = interval, keepAfter: Int = keepAfter) async throws -> Bool {
        let acknowledgement = Progress.discreteProgress(totalUnitCount: 1)
        var info = tap.userInfo
        info["acknowledgement"] = acknowledgement
        for attempt in 1...max(attempts, 1) {
            center.post(name: notification, object: nil, userInfo: info)
            if acknowledgement.isFinished { return true }
            // A tap that cannot be kept still goes on being posted.
            if attempt == keepAfter, let folder { try? ActionTapKeeper.keep(tap, in: folder) }
            try await Task.sleep(nanoseconds: interval)
        }
        return acknowledgement.isFinished
    }

    /// The same for a tap made here, kept nowhere. `isOn` is the state the person asked a toggle for; a button has none.
    @discardableResult
    public static func post(activityId: String, actionId: String, isOn: Bool? = nil, center: NotificationCenter = .default,
                            attempts: Int = attempts, interval: UInt64 = interval) async throws -> Bool {
        try await post(ActionTap(activityId: activityId, actionId: actionId, isOn: isOn), center: center, keepingIn: nil,
                       attempts: attempts, interval: interval)
    }
}
