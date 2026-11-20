import Foundation

/// A tap on a layout button or toggle, as the app receives it. `activityKey` is ActivityKit's for the activity, or, once
/// ActivityKit no longer lists it, the key the widget drew the button with; absent without either. `isOn` is the state
/// the person asked a toggle for, absent for a button. `tapId` stays with the tap from the intent to the app, in this
/// launch or a later one; `late` says that the app did not take the tap while its intent posted it, and it was kept.
public struct LiveActivityAction: Encodable, Equatable, Sendable {
    public let activityId: String
    public let actionId: String
    public let activityKey: String?
    public let isOn: Bool?
    public let tapId: String?
    /// When the person tapped, in epoch milliseconds.
    public let tappedAt: Double?
    /// The revision of the content that was shown.
    public let revision: Int64?
    public let late: Bool
    public init(activityId: String, actionId: String, activityKey: String?, isOn: Bool? = nil, tapId: String? = nil,
                tappedAt: Double? = nil, revision: Int64? = nil, late: Bool = false) {
        self.activityId = activityId; self.actionId = actionId; self.activityKey = activityKey; self.isOn = isOn
        self.tapId = tapId; self.tappedAt = tappedAt; self.revision = revision; self.late = late
    }
}

/// Receives the taps that `ActivityKitActionIntent.perform()` posts in the app process (`ActionPost`) and hands them
/// to the registered sink on its own serial queue, never the main thread. It observes from its creation and keeps the
/// latest 16 taps until a sink is registered. A tap is acknowledged when the sink has returned from it: until then the
/// intent posts it again every 100 ms and keeps an app that the system launched for the tap running. A post of a tap
/// that waits here or is acknowledged is ignored.
///
/// A tap that the intent kept on disk because the app did not take it at once (`ActionTapKeeper`) is handed to the
/// sink when one registers, with the waiting ones, in the order of the taps; its file is removed once the sink has it.
/// A tap is handed on once in a process, whether it came posted or kept. A kept tap older than `keptFor` is dropped.
public final class ActionRelay {
    /// Named after the project (github.com/1eedaegon/activitykit-rs), so that no other library posts it.
    public static let notification = Notification.Name("io.github.1eedaegon.activitykit.action")
    public static let pendingLimit = 16
    /// An activity lives at most 8 hours, and its card 4 more: a tap kept longer is of an activity that is gone.
    public static let keptFor: TimeInterval = 12 * 3600
    /// The folder where the intent keeps taps: `Application Support/activitykit/taps` of the app (`ActionTapKeeper`).
    public static var keptTaps: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("activitykit", isDirectory: true).appendingPathComponent("taps", isDirectory: true)
    }
    /// The ids of the latest taps handed on, so that a tap that comes posted and kept is handed on once.
    static let rememberedLimit = 64
    private typealias Tap = (action: LiveActivityAction, acknowledgement: Progress)
    private let queue = DispatchQueue(label: "io.github.1eedaegon.activitykit.actions")
    private let center: NotificationCenter
    private let folder: URL?
    private let activityKey: (String) -> String?
    private var observer: NSObjectProtocol?
    private var sink: ((LiveActivityAction) -> Void)?
    private var pending: [Tap] = []
    private var handedOn: [String] = []

    /// `keptIn` is the folder of kept taps: the app's (`keptTaps`) in the bridge, none or a test's own elsewhere.
    public init(center: NotificationCenter = .default, keptIn folder: URL? = nil, activityKey: @escaping (String) -> String?) {
        self.center = center
        self.folder = folder
        self.activityKey = activityKey
        observer = center.addObserver(forName: Self.notification, object: nil, queue: nil) { [weak self] in self?.receive($0) }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }

    /// Delivers the waiting and the kept taps and every later one to `sink`. Returns at once.
    public func register(_ sink: @escaping (LiveActivityAction) -> Void) {
        queue.async {
            self.sink = sink
            let waiting = self.pending
            self.pending = []
            let kept = self.kept().filter { kept in !waiting.contains { $0.action.tapId == kept.action.tapId } }
            // In the order of the taps; one that does not say when keeps its place after them.
            (waiting + kept).enumerated()
                .sorted { ($0.element.action.tappedAt ?? .infinity, $0.offset) < ($1.element.action.tappedAt ?? .infinity, $1.offset) }
                .forEach { self.deliver($0.element) }
        }
    }

    private func receive(_ notification: Notification) {
        guard let info = notification.userInfo, let activityId = info["activityId"] as? String,
              let actionId = info["actionId"] as? String, let acknowledgement = info["acknowledgement"] as? Progress else { return }
        queue.async {
            guard !acknowledgement.isFinished, !self.pending.contains(where: { $0.acknowledgement === acknowledgement }) else { return }
            let tapId = info["id"] as? String
            // Handed on already from its kept copy: the intent stops posting it.
            if let tapId, self.handedOn.contains(tapId) { return Self.acknowledge(acknowledgement) }
            let action = LiveActivityAction(activityId: activityId, actionId: actionId,
                                            activityKey: self.activityKey(activityId) ?? info["tappedKey"] as? String,
                                            isOn: info["isOn"] as? Bool, tapId: tapId, tappedAt: info["at"] as? Double,
                                            revision: (info["revision"] as? NSNumber)?.int64Value)
            let tap = (action, acknowledgement)
            if self.sink != nil { return self.deliver(tap) }
            self.pending.append(tap)
            // A dropped tap is acknowledged too, so that its intent stops posting it. It stays kept on disk.
            if self.pending.count > Self.pendingLimit { Self.acknowledge(self.pending.removeFirst().acknowledgement) }
        }
    }

    /// Runs on the queue. The bridge's sink returns once the app has taken the tap, or after its wait.
    private func deliver(_ tap: Tap) {
        sink?(tap.action)
        Self.acknowledge(tap.acknowledgement)
        guard let id = tap.action.tapId else { return }
        handedOn = Array((handedOn + [id]).suffix(Self.rememberedLimit))
        if let folder, let at = tap.action.tappedAt {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(Self.fileName(id: id, at: at)))
        }
    }

    /// The file of a kept tap, as `ActionTapKeeper` names it.
    static func fileName(id: String, at: Double) -> String { "\(String(format: "%015.0f", at))-\(id).json" }

    /// What a kept tap's file says; members of a later form are skipped.
    private struct KeptTap: Decodable {
        let id: String
        let activityId: String
        let actionId: String
        let isOn: Bool?
        let activityKey: String?
        let revision: Int64?
        let at: Double
    }

    /// Runs on the queue. The taps kept on disk, oldest first; a file that cannot be read, or of a tap too old, is
    /// removed.
    private func kept() -> [Tap] {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        let oldest = (Date().timeIntervalSince1970 - Self.keptFor) * 1000
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            let file = folder.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: file), let tap = try? JSONDecoder().decode(KeptTap.self, from: data), tap.at >= oldest else {
                try? FileManager.default.removeItem(at: file)
                return nil
            }
            let action = LiveActivityAction(activityId: tap.activityId, actionId: tap.actionId,
                                            activityKey: activityKey(tap.activityId) ?? tap.activityKey, isOn: tap.isOn, tapId: tap.id,
                                            tappedAt: tap.at, revision: tap.revision, late: true)
            return (action, Progress.discreteProgress(totalUnitCount: 1))
        }
    }

    private static func acknowledge(_ acknowledgement: Progress) {
        acknowledgement.completedUnitCount = acknowledgement.totalUnitCount
    }
}
