import CryptoKit
import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

/// A store of whole v1 activities. The receipt file is a `FileReceiptStore`.
@MainActor
public protocol ActivityReceiptStore {
    func load() throws -> [NativeActivity]
    func save(_ activities: [NativeActivity]) throws
}

/// `full` keeps the accepted snapshot, `redacted` only its SHA-256 digest. A digest hides a snapshot only while it cannot
/// be guessed: hashing candidates recovers a snapshot made only of guessable values, such as a flag, a small number or a
/// short word.
public enum ReceiptMode: String, Codable, Sendable { case full, redacted }

/// What a receipt says about its activity besides the content.
public struct ReceiptSummary: Hashable, Sendable {
    public let activityKey: String
    public let schemaVersion: Int
    /// The v1 template; layout activities have none.
    public let template: String?
    public let fingerprint: String
    public init(activityKey: String, schemaVersion: Int, template: String?, fingerprint: String) {
        self.activityKey = activityKey; self.schemaVersion = schemaVersion; self.template = template; self.fingerprint = fingerprint
    }
}

private struct ReceiptMemberKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private func memberCount(_ decoder: Decoder) throws -> Int { try decoder.container(keyedBy: ReceiptMemberKey.self).allKeys.count }
private func invalidReceipt(_ decoder: Decoder) -> DecodingError {
    .dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid activity receipt."))
}

private struct DigestContent: Codable {
    let digest: String
    private enum CodingKeys: String, CodingKey { case digest }
    init(digest: String) { self.digest = digest }
    init(from decoder: Decoder) throws {
        digest = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .digest)
        guard try memberCount(decoder) == 1 else { throw invalidReceipt(decoder) }
    }
}

/// One entry of the receipt file: `{ id, activityKey, schemaVersion, template (v1 only), state, revision, fingerprint, content }`.
/// `content` is the accepted snapshot, or `{ "digest": … }` when redacted. Layouts are never stored.
public struct StoredReceipt: Codable, Sendable {
    public enum Content: Sendable {
        case template(ActivitySnapshot)
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

    private enum CodingKeys: String, CodingKey { case id, activityKey, schemaVersion, template, state, revision, fingerprint, content }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        summary = ReceiptSummary(activityKey: try container.decode(String.self, forKey: .activityKey),
                                 schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
                                 template: try container.decodeIfPresent(String.self, forKey: .template),
                                 fingerprint: try container.decode(String.self, forKey: .fingerprint))
        state = try container.decode(String.self, forKey: .state)
        revision = try container.decode(Int64.self, forKey: .revision)
        if let digest = try? container.decode(DigestContent.self, forKey: .content) { content = .digest(digest.digest) }
        else if summary.schemaVersion == 1 { content = .template(try container.decode(ActivitySnapshot.self, forKey: .content)) }
        else { content = .layout(try container.decode(LayoutSnapshot.self, forKey: .content)) }
        guard try memberCount(decoder) == (summary.template == nil ? 7 : 8) else { throw invalidReceipt(decoder) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(summary.activityKey, forKey: .activityKey)
        try container.encode(summary.schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(summary.template, forKey: .template)
        try container.encode(state, forKey: .state)
        try container.encode(revision, forKey: .revision)
        try container.encode(summary.fingerprint, forKey: .fingerprint)
        switch content {
        case .template(let snapshot): try container.encode(snapshot, forKey: .content)
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
        case .template(let snapshot): digest = try ReceiptDigest.of(snapshot)
        case .layout(let snapshot): digest = try ReceiptDigest.of(snapshot)
        case .digest: return self
        }
        return StoredReceipt(id: id, summary: summary, state: state, revision: revision, content: .digest(digest))
    }
    fileprivate func validate() throws {
        let valid: Bool
        switch (summary.schemaVersion, summary.template, content) {
        case let (1, template?, .template(snapshot)):
            try snapshot.validate(template: template)
            valid = snapshot.revision == revision
        case let (1, template?, .digest): valid = ["progress", "timer"].contains(template)
        case let (2, nil, .layout(snapshot)):
            try snapshot.validate()
            valid = snapshot.revision == revision
        case (2, nil, .digest): valid = true
        default: valid = false
        }
        guard valid else { throw ActivityFailure("NATIVE_ERROR", "Invalid activity receipt.") }
    }
}

/// SHA-256 of a snapshot's sorted-keys JSON, in lower-case hex.
enum ReceiptDigest {
    static func of<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Accepted snapshots are persisted because ActivityKit's read model can lag an awaited update.
/// One file holds the receipts of both contract versions.
@MainActor
public struct FileReceiptStore {
    public let mode: ReceiptMode
    private let url: URL
    private let legacyURL: URL?
    private let maxBytes = 2_097_152
    private let legacyMaxBytes = 1_048_576
    private let maxReceipts = 256
    public init(url: URL, mode: ReceiptMode = .full) { self.init(url: url, mode: mode, legacyURL: nil) }
    private init(url: URL, mode: ReceiptMode, legacyURL: URL?) { self.url = url; self.mode = mode; self.legacyURL = legacyURL }

    /// `receipts-v2.json` in the folder. A `receipts-v1.json` beside it is converted and deleted on the first load.
    public static func store(in folder: URL, mode: ReceiptMode) -> FileReceiptStore {
        FileReceiptStore(url: folder.appendingPathComponent("receipts-v2.json"), mode: mode,
                         legacyURL: folder.appendingPathComponent("receipts-v1.json"))
    }
    public static func applicationStore(mode: ReceiptMode = .full) throws -> FileReceiptStore {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return store(in: directory.appendingPathComponent("activitykit"), mode: mode)
    }

    /// Every entry. In redacted mode stored snapshots are replaced by their digests, in memory and on disk.
    public func load() throws -> [StoredReceipt] {
        do {
            var entries = try read(url, limit: maxBytes).map { try JSONDecoder().decode([StoredReceipt].self, from: $0) } ?? []
            let legacy = try legacyURL.flatMap { try read($0, limit: legacyMaxBytes) }.map(legacyEntries)
            if let legacy = legacy {
                let migrated = Set(legacy.map(\.id))
                entries = entries.filter { !migrated.contains($0.id) } + legacy
            }
            for entry in entries { try entry.validate() }
            guard [1, 2].allSatisfy({ version in entries.filter { $0.summary.schemaVersion == version }.count <= maxReceipts }) else {
                throw ActivityFailure("NATIVE_ERROR", "Too many activity receipts.")
            }
            let kept = mode == .redacted ? try entries.map { try $0.redacted() } : entries
            if legacy != nil || kept.map(\.isDigest) != entries.map(\.isDigest) {
                try write(kept)
                if let legacyURL = legacyURL, legacy != nil { try FileManager.default.removeItem(at: legacyURL) }
            }
            return kept
        } catch { throw ActivityFailure("NATIVE_ERROR", "Unable to read local activity receipts.") }
    }

    /// Writes every entry, as digests in redacted mode.
    public func save(_ entries: [StoredReceipt]) throws {
        do { try write(mode == .redacted ? entries.map { try $0.redacted() } : entries) }
        catch { throw ActivityFailure("NATIVE_ERROR", "Unable to save local activity receipts.") }
    }

    /// Writes one contract version's entries and keeps the other version's.
    func replace(_ entries: [StoredReceipt], version: Int) throws {
        let others: [StoredReceipt]
        do { others = try load().filter { $0.summary.schemaVersion != version } }
        catch { throw ActivityFailure("NATIVE_ERROR", "Unable to save local activity receipts.") }
        try save(others + entries)
    }

    private func read(_ file: URL, limit: Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ActivityFailure("NATIVE_ERROR", "Activity receipt storage is too large.") }
        return data
    }

    /// The `receipts-v1.json` of earlier versions, read with the rules it was written with.
    private func legacyEntries(_ data: Data) throws -> [StoredReceipt] {
        let activities = try JSONDecoder().decode([NativeActivity].self, from: data)
        guard activities.count <= maxReceipts else { throw ActivityFailure("NATIVE_ERROR", "Too many activity receipts.") }
        for activity in activities { try activity.snapshot.validate(template: activity.attributes.template) }
        return activities.map { StoredReceipt($0) }
    }

    private func write(_ entries: [StoredReceipt]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(entries)
        guard data.count <= maxBytes else { throw ActivityFailure("NATIVE_ERROR", "Activity receipt storage is too large.") }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Where one contract version's receipts are kept.
struct ReceiptStorage<Activity: LifecycleActivity> {
    let load: @MainActor () throws -> [Receipt<Activity>]
    let save: @MainActor ([Receipt<Activity>]) throws -> Void

    static func memory() -> ReceiptStorage { ReceiptStorage(load: { [] }, save: { _ in }) }
    static func file(_ store: FileReceiptStore) -> ReceiptStorage {
        ReceiptStorage(load: { try store.load().filter { $0.summary.schemaVersion == Activity.schemaVersion }.map { Receipt(entry: $0) } },
                       save: { try store.replace($0.map(\.entry), version: Activity.schemaVersion) })
    }
}

extension ReceiptStorage where Activity == NativeActivity {
    static func custom(_ store: ActivityReceiptStore) -> ReceiptStorage {
        ReceiptStorage(load: { try store.load().map { Receipt(activity: $0) } }, save: { try store.save($0.compactMap(\.activity)) })
    }
}
