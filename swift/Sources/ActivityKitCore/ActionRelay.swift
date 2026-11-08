import Foundation

/// A tap on a layout button, as the app receives it. `activityKey` is absent once ActivityKit no longer knows the activity.
public struct LiveActivityAction: Encodable, Equatable, Sendable {
    public let activityId: String
    public let actionId: String
    public let activityKey: String?
    public init(activityId: String, actionId: String, activityKey: String?) {
        self.activityId = activityId; self.actionId = actionId; self.activityKey = activityKey
    }
}

/// Receives the taps that `ActivityKitActionIntent.perform()` (templates/ios) posts in the app process and hands them
/// to the registered sink on its own serial queue, never the main thread. It observes from its creation and keeps the
/// latest 16 taps until a sink is registered. A tap is acknowledged when the sink has returned from it: until then the
/// intent posts it again every 100 ms and keeps an app that the system launched for the tap running. A post of a tap
/// that waits here or is acknowledged is ignored.
public final class ActionRelay {
    public static let notification = Notification.Name("activitykit.action")
    public static let pendingLimit = 16
    private typealias Tap = (action: LiveActivityAction, acknowledgement: Progress)
    private let queue = DispatchQueue(label: "activitykit.actions")
    private let center: NotificationCenter
    private let activityKey: (String) -> String?
    private var observer: NSObjectProtocol?
    private var sink: ((LiveActivityAction) -> Void)?
    private var pending: [Tap] = []

    public init(center: NotificationCenter = .default, activityKey: @escaping (String) -> String?) {
        self.center = center
        self.activityKey = activityKey
        observer = center.addObserver(forName: Self.notification, object: nil, queue: nil) { [weak self] in self?.receive($0) }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Delivers the waiting taps and every later one to `sink`. Returns at once.
    public func register(_ sink: @escaping (LiveActivityAction) -> Void) {
        queue.async {
            self.sink = sink
            let waiting = self.pending
            self.pending = []
            waiting.forEach(self.deliver)
        }
    }

    private func receive(_ notification: Notification) {
        guard let info = notification.userInfo, let activityId = info["activityId"] as? String,
              let actionId = info["actionId"] as? String, let acknowledgement = info["acknowledgement"] as? Progress else { return }
        queue.async {
            guard !acknowledgement.isFinished, !self.pending.contains(where: { $0.acknowledgement === acknowledgement }) else { return }
            let tap = (LiveActivityAction(activityId: activityId, actionId: actionId, activityKey: self.activityKey(activityId)), acknowledgement)
            if self.sink != nil { return self.deliver(tap) }
            self.pending.append(tap)
            // A dropped tap is acknowledged too, so that its intent stops posting it.
            if self.pending.count > Self.pendingLimit { Self.acknowledge(self.pending.removeFirst().acknowledgement) }
        }
    }

    /// Runs on the queue. The bridge's sink returns once the app has taken the tap, or after its wait.
    private func deliver(_ tap: Tap) {
        sink?(tap.action)
        Self.acknowledge(tap.acknowledgement)
    }

    private static func acknowledge(_ acknowledgement: Progress) {
        acknowledgement.completedUnitCount = acknowledgement.totalUnitCount
    }
}
