import CryptoKit
import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

/// `full` keeps the accepted snapshot, `redacted` only its SHA-256 digest. A digest hides a snapshot only while it cannot
/// be guessed: hashing candidates recovers a snapshot made only of guessable values, such as a flag, a small number or a
/// short word.
public enum ReceiptMode: String, Codable, Sendable { case full, redacted }

/// What a receipt says about its activity besides the content.
public struct ReceiptSummary: Hashable, Sendable {
    public let activityKey: String
    public let schemaVersion: Int
    public let fingerprint: String
    public init(activityKey: String, schemaVersion: Int, fingerprint: String) {
        self.activityKey = activityKey; self.schemaVersion = schemaVersion; self.fingerprint = fingerprint
    }
}

private struct DigestContent: Codable {
    let digest: String
}

/// One entry of the receipt file: `{ id, activityKey, schemaVersion, state, revision, fingerprint, content }`.
/// `content` is the accepted snapshot, values in plain text, or `{ "digest": … }` when redacted. Layouts are never
/// stored. A member that this version does not know, of a receipt that a later one wrote, is passed over.
public struct StoredReceipt: Codable, Sendable {
    public enum Content: Sendable {
        case layout(LayoutSnapshot)
        case digest(String)
    }
    public let id: String
    public let summary: ReceiptSummary
    public let state: String
    public let revision: Int64
    public let content: Content
    public init(id: String, summary: ReceiptSummary, state: String, revision: Int64, content: Content) {
        self.id = id; self.summary = summary; self.state = state; self.revision = revision; self.content = content
    }
    init<Activity: LifecycleActivity>(_ activity: Activity) {
        self.init(id: activity.id, summary: activity.summary, state: activity.state,
                  revision: Activity.revision(of: activity.snapshot), content: Activity.content(activity.snapshot))
    }

    private enum CodingKeys: String, CodingKey { case id, activityKey, schemaVersion, state, revision, fingerprint, content }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        summary = ReceiptSummary(activityKey: try container.decode(String.self, forKey: .activityKey),
                                 schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
                                 fingerprint: try container.decode(String.self, forKey: .fingerprint))
        state = try container.decode(String.self, forKey: .state)
        revision = try container.decode(Int64.self, forKey: .revision)
        if let digest = try? container.decode(DigestContent.self, forKey: .content) { content = .digest(digest.digest) }
        else { content = .layout(try container.decode(LayoutSnapshot.self, forKey: .content)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(summary.activityKey, forKey: .activityKey)
        try container.encode(summary.schemaVersion, forKey: .schemaVersion)
        try container.encode(state, forKey: .state)
        try container.encode(revision, forKey: .revision)
        try container.encode(summary.fingerprint, forKey: .fingerprint)
        switch content {
        case .layout(let snapshot): try container.encode(snapshot, forKey: .content)
        case .digest(let digest): try container.encode(DigestContent(digest: digest), forKey: .content)
        }
    }

    fileprivate var isDigest: Bool {
        if case .digest = content { return true } else { return false }
    }
    fileprivate func redacted() throws -> StoredReceipt {
        let digest: String
        switch content {
        case .layout(let snapshot): digest = try ReceiptDigest.of(snapshot.content)
        case .digest: return self
        }
        return StoredReceipt(id: id, summary: summary, state: state, revision: revision, content: .digest(digest))
    }
    fileprivate func validate() throws {
        let valid: Bool
        switch (summary.schemaVersion, content) {
        case let (2, .layout(snapshot)):
            try snapshot.validate()
            valid = snapshot.revision == revision
        case (2, .digest): valid = true
        default: valid = false
        }
        guard valid else { throw ActivityFailure("NATIVE_ERROR", "Invalid activity receipt.") }
    }
}

/// An entry of the receipt file, or nil when it is no receipt that this version can read.
private struct ReadableReceipt: Decodable {
    let receipt: StoredReceipt?
    init(from decoder: Decoder) throws { receipt = try? StoredReceipt(from: decoder) }
}

/// SHA-256 of a value's sorted-keys JSON, in lower-case hex; a snapshot's digest covers its content, not its timestamp.
enum ReceiptDigest {
    static func of<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Accepted snapshots are persisted because ActivityKit's read model can lag an awaited update. In `full` mode the file
/// holds the latest values in plain text, readable to the app once the device was first unlocked after a restart
/// (`completeFileProtectionUntilFirstUserAuthentication` on iOS).
@MainActor
public struct FileReceiptStore {
    public let mode: ReceiptMode
    private let url: URL
    private static let maxBytes = 2_097_152
    private static let maxReceipts = 256
    /// The data protection of the receipt file on iOS.
    public static let protection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication
    public init(url: URL, mode: ReceiptMode = .full) { self.url = url; self.mode = mode }

    /// `receipts-v2.json` in the folder.
    public static func store(in folder: URL, mode: ReceiptMode) -> FileReceiptStore {
        FileReceiptStore(url: folder.appendingPathComponent("receipts-v2.json"), mode: mode)
    }
    public static func applicationStore(mode: ReceiptMode = .full) throws -> FileReceiptStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return store(in: directory.appendingPathComponent("activitykit"), mode: mode)
    }

    /// Every entry that can be read, the newest 256. A receipt that cannot be read costs that receipt, not the list,
    /// and a file that is no list of receipts holds none; the file stays as it is until the next save, which writes
    /// what was read. In redacted mode stored snapshots are replaced by their digests, in memory and on disk. A file
    /// that cannot be opened is an error.
    public func load() throws -> [StoredReceipt] {
        do {
            guard let data = try read(url) else { return [] }
            let entries = Self.receipts(in: data)
            let kept = mode == .redacted ? try entries.map { try $0.redacted() } : entries
            if kept.map(\.isDigest) != entries.map(\.isDigest) { try write(kept) }
            return kept
        } catch { throw ActivityFailure("NATIVE_ERROR", "Unable to read local activity receipts.") }
    }

    /// The valid receipts of a file, oldest first as they are kept, at most the newest 256.
    private static func receipts(in data: Data) -> [StoredReceipt] {
        guard data.count <= maxBytes, let list = try? JSONDecoder().decode([ReadableReceipt].self, from: data) else { return [] }
        return Array(list.compactMap(\.receipt).filter { (try? $0.validate()) != nil }.suffix(maxReceipts))
    }

    /// Writes every entry, as digests in redacted mode.
    public func save(_ entries: [StoredReceipt]) throws {
        do { try write(mode == .redacted ? entries.map { try $0.redacted() } : entries) }
        catch { throw ActivityFailure("NATIVE_ERROR", "Unable to save local activity receipts.") }
    }

    /// The file's bytes, one more than a file may have when it has more; nil without a file.
    private func read(_ file: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        return try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
    }

    private func write(_ entries: [StoredReceipt]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.maxBytes else { throw ActivityFailure("NATIVE_ERROR", "Activity receipt storage is too large.") }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, Self.protection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Where the receipts are kept.
struct ReceiptStorage<Activity: LifecycleActivity> {
    let load: @MainActor () throws -> [Receipt<Activity>]
    let save: @MainActor ([Receipt<Activity>]) throws -> Void

    static func memory() -> ReceiptStorage { ReceiptStorage(load: { [] }, save: { _ in }) }
    static func file(_ store: FileReceiptStore) -> ReceiptStorage {
        ReceiptStorage(load: { try store.load().map { Receipt(entry: $0) } }, save: { try store.save($0.map(\.entry)) })
    }
}
