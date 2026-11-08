import Foundation

/// How a button's intent hands its tap to activitykit's bridge in the app process: it posts the tap with an
/// acknowledgement every `interval` until the bridge acknowledges it, at most `attempts` times (5 s). The bridge
/// acknowledges once the app has taken the event, so the wait keeps an app that the system launched for the tap running.
/// Only Foundation, so that the host tests run it.
public enum ActionPost {
    /// The notification that `ActionRelay` observes.
    public static let notification = Notification.Name("activitykit.action")
    public static let attempts = 50
    /// Between two posts, in nanoseconds.
    public static let interval: UInt64 = 100_000_000

    /// Posts the tap until it is acknowledged or the attempts run out, and says whether it was acknowledged.
    @discardableResult
    public static func post(activityId: String, actionId: String, center: NotificationCenter = .default,
                            attempts: Int = attempts, interval: UInt64 = interval) async throws -> Bool {
        let acknowledgement = Progress.discreteProgress(totalUnitCount: 1)
        let info: [AnyHashable: Any] = ["activityId": activityId, "actionId": actionId, "acknowledgement": acknowledgement]
        for _ in 0..<attempts {
            center.post(name: notification, object: nil, userInfo: info)
            if acknowledgement.isFinished { return true }
            try await Task.sleep(nanoseconds: interval)
        }
        return acknowledgement.isFinished
    }
}
