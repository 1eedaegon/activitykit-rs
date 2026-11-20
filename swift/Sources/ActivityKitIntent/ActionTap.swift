import Foundation

/// One tap on a button or a toggle, as the intent hands it to activitykit's bridge and, when the app does not take it
/// at once, keeps it in the app's container: the id stays with the tap from the intent to the app's handler, in this
/// launch or a later one. Only Foundation, so that the host tests run it.
public struct ActionTap: Codable, Equatable, Sendable {
    /// The form of a kept tap; a reader skips members it does not know.
    public static let format = 1
    public let format: Int
    public let id: String
    public let activityId: String
    public let actionId: String
    /// The state the person asked a toggle for; nil for a button.
    public let isOn: Bool?
    /// The activity's key as the widget drew it, which stays when ActivityKit no longer lists the activity.
    public let activityKey: String?
    /// The revision of the content that was shown.
    public let revision: Int64?
    /// When the person tapped, in epoch milliseconds.
    public let at: Double

    public init(id: String = UUID().uuidString, activityId: String, actionId: String, isOn: Bool? = nil, activityKey: String? = nil,
                revision: Int64? = nil, at: Date = Date()) {
        format = Self.format
        self.id = id; self.activityId = activityId; self.actionId = actionId; self.isOn = isOn
        self.activityKey = activityKey; self.revision = revision; self.at = (at.timeIntervalSince1970 * 1000).rounded()
    }

    /// What the bridge reads from a post.
    var userInfo: [AnyHashable: Any] {
        var info: [AnyHashable: Any] = ["activityId": activityId, "actionId": actionId, "id": id, "at": at]
        if let isOn { info["isOn"] = isOn }
        if let activityKey { info["tappedKey"] = activityKey }
        if let revision { info["revision"] = revision }
        return info
    }
}

/// Where the intent keeps a tap that the app has not taken yet: one small file for each, so that the intent writes and
/// the bridge removes without a lock between them. The name begins with the time of the tap, so that the oldest are
/// first by name. At most `limit` taps are kept; a newer one pushes the oldest out.
public enum ActionTapKeeper {
    public static let limit = 32

    /// `Application Support/activitykit/taps` of the app, beside its receipts; nil where the system has no such folder.
    public static var folder: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("activitykit", isDirectory: true).appendingPathComponent("taps", isDirectory: true)
    }

    /// The file of a tap: its time, zero-padded so that names sort by it, and its id.
    public static func fileName(of tap: ActionTap) -> String {
        "\(String(format: "%015.0f", tap.at))-\(tap.id).json"
    }

    /// Writes the tap, and drops the oldest beyond the limit. Throws when the folder cannot be written; the tap then
    /// lives only as long as its intent posts it.
    public static func keep(_ tap: ActionTap, in folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(tap).write(to: folder.appendingPathComponent(fileName(of: tap)), options: .atomic)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        for name in names.dropLast(limit) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }
    }
}
