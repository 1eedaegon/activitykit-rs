import Foundation

/// How the intent of a button or a toggle hands its tap to activitykit's bridge in the app process: it posts the tap with an
/// acknowledgement every `interval` until the bridge acknowledges it, at most `attempts` times (5 s). The bridge
/// acknowledges once the app has taken the event, so the wait keeps an app that the system launched for the tap running.
/// Only Foundation, so that the host tests run it.
public enum ActionPost {
    /// The notification that `ActionRelay` observes.
    public static let notification = Notification.Name("io.github.1eedaegon.activitykit.action")
    public static let attempts = 50
    /// Between two posts, in nanoseconds.
    public static let interval: UInt64 = 100_000_000

    /// The state a tap asks for, from the two values the intent carries: a toggle's tap says that it is one and which
    /// state it asks for, and any other tap asks for none. The intent cannot carry one optional value for this: the
    /// system hands the app a value that was never set as false, and a button's tap would ask to switch off.
    public static func state(isToggle: Bool, isOn: Bool) -> Bool? { isToggle ? isOn : nil }

    /// Posts the tap until it is acknowledged or the attempts run out, and says whether it was acknowledged. `isOn` is
    /// the state the person asked a toggle for; a button has none.
    @discardableResult
    public static func post(activityId: String, actionId: String, isOn: Bool? = nil, center: NotificationCenter = .default,
                            attempts: Int = attempts, interval: UInt64 = interval) async throws -> Bool {
        let acknowledgement = Progress.discreteProgress(totalUnitCount: 1)
        var info: [AnyHashable: Any] = ["activityId": activityId, "actionId": actionId, "acknowledgement": acknowledgement]
        if let isOn { info["isOn"] = isOn }
        for _ in 0..<attempts {
            center.post(name: notification, object: nil, userInfo: info)
            if acknowledgement.isFinished { return true }
            try await Task.sleep(nanoseconds: interval)
        }
        return acknowledgement.isFinished
    }
}
