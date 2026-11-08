import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

public struct NativeActivity: Codable, Sendable {
    public let id: String
    public let attributes: LiveActivityAttributes
    public let snapshot: ActivitySnapshot
    public let state: String
    public init(id: String, attributes: LiveActivityAttributes, snapshot: ActivitySnapshot, state: String) {
        self.id = id; self.attributes = attributes; self.snapshot = snapshot; self.state = state
    }
    public var record: ActivityRecord { ActivityRecord(activity: self) }
}

public struct ActivityRecord: Encodable, Sendable {
    public let id: String
    public let activityKey: String
    public let schemaVersion: Int
    public let template: String
    public let snapshot: ActivitySnapshot
    public let backend = "activityKit"
    public let state: String
    public let visibility = "unknown"
    public let degradedFeatures: [String] = []
    public let promotionRequested = false
    public let promotionState = "notApplicable"
    public init(activity: NativeActivity) {
        id = activity.id; activityKey = activity.attributes.activityKey
        schemaVersion = activity.attributes.schemaVersion; template = activity.attributes.template
        snapshot = activity.snapshot; state = activity.state
    }
    init(entry: StoredReceipt, snapshot: ActivitySnapshot) {
        id = entry.id; activityKey = entry.summary.activityKey; schemaVersion = entry.summary.schemaVersion
        template = entry.summary.template ?? ""; self.snapshot = snapshot; state = entry.state
    }
}

@MainActor
public protocol ActivityBackend: AnyObject {
    func preflightStart() throws
    func list() async -> [NativeActivity]
    func start(_ attributes: LiveActivityAttributes, snapshot: ActivitySnapshot) async throws -> NativeActivity
    func update(_ activity: NativeActivity, snapshot: ActivitySnapshot) async throws -> NativeActivity
    func end(_ activity: NativeActivity, policy: EndPolicy) async throws -> NativeActivity
    /// Ends the activity without new content, so the system keeps what it last published.
    func endKeepingContent(_ activity: NativeActivity, policy: EndPolicy) async throws -> NativeActivity
}

extension ActivityBackend {
    /// A backend that does not implement it ends with `activity.snapshot`.
    public func endKeepingContent(_ activity: NativeActivity, policy: EndPolicy) async throws -> NativeActivity {
        try await end(activity, policy: policy)
    }
}

/// Holds the lock across suspension points; an actor alone would permit reentrant updates.
@MainActor
final class SerialOperationQueue {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func run<T>(_ operation: () async throws -> T) async rethrows -> T {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await operation()
    }
}

/// What the shared lifecycle needs from one contract version's activity.
protocol LifecycleActivity: Sendable {
    associatedtype Attributes
    associatedtype Snapshot: Equatable & Encodable & Sendable
    associatedtype Record
    static var schemaVersion: Int { get }
    static var instancePrefix: String { get }
    static func content(_ snapshot: Snapshot) -> StoredReceipt.Content
    static func snapshot(in content: StoredReceipt.Content) -> Snapshot?
    static func revision(of snapshot: Snapshot) -> Int64
    /// The record of an activity that only its receipt knows; a redacted receipt shows an empty snapshot.
    static func record(_ entry: StoredReceipt) -> Record
    var id: String { get }
    var state: String { get }
    var snapshot: Snapshot { get }
    var summary: ReceiptSummary { get }
    var record: Record { get }
    func with(snapshot: Snapshot, state: String) -> Self
}

extension NativeActivity: LifecycleActivity {
    typealias Attributes = LiveActivityAttributes
    static let schemaVersion = 1
    static let instancePrefix = "la-ios-"
    static func content(_ snapshot: ActivitySnapshot) -> StoredReceipt.Content { .template(snapshot) }
    static func snapshot(in content: StoredReceipt.Content) -> ActivitySnapshot? {
        if case .template(let snapshot) = content { return snapshot } else { return nil }
    }
    static func revision(of snapshot: ActivitySnapshot) -> Int64 { snapshot.revision }
    static func record(_ entry: StoredReceipt) -> ActivityRecord {
        ActivityRecord(entry: entry, snapshot: snapshot(in: entry.content)
            ?? ActivitySnapshot(revision: entry.revision, title: "", status: "", progress: nil, timer: nil, staleAt: nil))
    }
    var summary: ReceiptSummary {
        ReceiptSummary(activityKey: attributes.activityKey, schemaVersion: attributes.schemaVersion, template: attributes.template,
                       fingerprint: attributes.initialFingerprint)
    }
    func with(snapshot: ActivitySnapshot, state: String) -> NativeActivity {
        NativeActivity(id: id, attributes: attributes, snapshot: snapshot, state: state)
    }
}

/// The system calls of one contract version.
struct LifecycleBackend<Activity: LifecycleActivity> {
    let preflight: @MainActor () throws -> Void
    let list: @MainActor () async -> [Activity]
    let start: @MainActor (Activity.Attributes, Activity.Snapshot) async throws -> Activity
    let update: @MainActor (Activity, Activity.Snapshot) async throws -> Activity
    let end: @MainActor (Activity, EndPolicy) async throws -> Activity
    /// Ends without new content: the system keeps what it last published.
    let endKeepingContent: @MainActor (Activity, EndPolicy) async throws -> Activity
}

extension LifecycleBackend where Activity == NativeActivity {
    init(_ backend: ActivityBackend) {
        self.init(preflight: { try backend.preflightStart() }, list: { await backend.list() },
                  start: { try await backend.start($0, snapshot: $1) }, update: { try await backend.update($0, snapshot: $1) },
                  end: { try await backend.end($0, policy: $1) }, endKeepingContent: { try await backend.endKeepingContent($0, policy: $1) })
    }
}

/// What the lifecycle remembers about one activity: the whole activity when this process or a custom
/// store knows it, else the stored entry.
struct Receipt<Activity: LifecycleActivity> {
    let entry: StoredReceipt
    let activity: Activity?
    init(activity: Activity) { self.activity = activity; entry = StoredReceipt(activity) }
    init(entry: StoredReceipt) { self.entry = entry; activity = nil }
    var id: String { entry.id }
    var state: String { entry.state }
    var snapshot: Activity.Snapshot? { activity?.snapshot ?? Activity.snapshot(in: entry.content) }
}

private func isLive(_ state: String) -> Bool { ["active", "stale"].contains(state) }
private func isTerminal(_ state: String) -> Bool { ["ended", "dismissed"].contains(state) }

/// The rules both contract versions share: idempotent start by fingerprint, revisions, tombstones and
/// receipts. One instance serves one contract version, so the versions never see each other's activities.
@MainActor
final class ActivityLifecycle<Activity: LifecycleActivity> {
    private let backend: LifecycleBackend<Activity>
    private let storage: ReceiptStorage<Activity>
    private let queue = SerialOperationQueue()
    private var receipts: [Receipt<Activity>] = []
    private var loaded = false
    private let tombstoneLimit = 128
    init(backend: LifecycleBackend<Activity>, storage: ReceiptStorage<Activity>) { self.backend = backend; self.storage = storage }

    private func load() throws {
        if loaded { return }
        receipts = try storage.load()
        loaded = true
    }

    private func remember(_ activity: Activity) throws { try remember(Receipt(activity: activity)) }

    private func remember(_ receipt: Receipt<Activity>) throws {
        let others = receipts.filter { $0.id != receipt.id }
        let active = others.filter { isLive($0.state) }
        let finished = others.filter { !isLive($0.state) }
        let candidates = active + Array(finished.suffix(tombstoneLimit - 1)) + [receipt]
        receipts = Array(candidates.suffix(256))
        try storage.save(receipts)
    }

    private func observed() async -> [Activity] {
        await backend.list().map { activity in
            guard let receipt = receipts.first(where: { $0.id == activity.id }) else { return activity }
            if isTerminal(receipt.state) {
                return receipt.activity ?? activity.with(snapshot: receipt.snapshot ?? activity.snapshot, state: receipt.state)
            }
            if let snapshot = receipt.snapshot, receipt.entry.revision > Activity.revision(of: activity.snapshot) {
                return activity.with(snapshot: snapshot, state: activity.state)
            }
            return activity
        }
    }

    func start(key: String, fingerprint: () throws -> String, snapshot: Activity.Snapshot,
               attributes: (String) throws -> Activity.Attributes) async throws -> Activity.Record {
        try await queue.run {
            try self.load()
            let existing = await self.observed().first { $0.summary.activityKey == key && isLive($0.state) }
            if let existing = existing {
                guard existing.summary.fingerprint == (try fingerprint()) else {
                    throw ActivityFailure("CONFLICT", "An activity with this key already exists with different input.")
                }
                return existing.record
            }
            try self.backend.preflight()
            let prepared = try attributes(Activity.instancePrefix + UUID().uuidString)
            let result = try await self.backend.start(prepared, snapshot)
            try self.remember(result)
            return result.record
        }
    }

    func update(id: String, snapshot: Activity.Snapshot, validate: (Activity) throws -> Void,
                check: (Activity) throws -> Void) async throws -> Activity.Record {
        try await queue.run {
            try self.load()
            let activity = try await self.active(id)
            try validate(activity)
            let receipt = self.receipts.first { $0.id == id }
            let current = Activity.revision(of: activity.snapshot), revision = Activity.revision(of: snapshot)
            let floor = max(current, receipt?.entry.revision ?? current)
            guard revision >= floor else {
                throw ActivityFailure("STALE_REVISION", "The revision is older than the current activity state.")
            }
            if revision == floor {
                let conflict = ActivityFailure("CONFLICT", "This revision already contains different state.")
                if revision == current {
                    guard snapshot == activity.snapshot else { throw conflict }
                    return activity.record
                }
                guard case .digest(let digest)? = receipt?.entry.content, digest == (try ReceiptDigest.of(snapshot)) else { throw conflict }
                return activity.with(snapshot: snapshot, state: activity.state).record
            }
            try check(activity)
            let observed = try await self.backend.update(activity, snapshot)
            let accepted = observed.with(snapshot: snapshot, state: observed.state)
            try self.remember(accepted)
            return accepted.record
        }
    }

    /// New final content for an end: the snapshot, its check against the activity, and the payload check.
    struct FinalContent {
        let snapshot: Activity.Snapshot
        let validate: (Activity) throws -> Void
        let check: (Activity) throws -> Void
    }

    func end(id: String, policy: EndPolicy, content: FinalContent? = nil) async throws -> Activity.Record {
        try await queue.run {
            try self.load()
            if let known = self.receipts.first(where: { $0.id == id && isTerminal($0.state) }) {
                if let activity = known.activity { return activity.record }
                if known.snapshot == nil, let shown = await self.observed().first(where: { $0.id == id }) { return shown.record }
                return Activity.record(known.entry)
            }
            if let terminal = await self.observed().first(where: { $0.id == id && isTerminal($0.state) }) {
                try self.remember(terminal)
                return terminal.record
            }
            try policy.validate()
            let activity = try await self.active(id)
            // Final content follows the rules of an update: the keys and types of the start, a revision not older than
            // the accepted one, and at the accepted revision only the same content.
            if let content {
                try content.validate(activity)
                let receipt = self.receipts.first { $0.id == id }
                let current = Activity.revision(of: activity.snapshot), revision = Activity.revision(of: content.snapshot)
                let floor = max(current, receipt?.entry.revision ?? current)
                guard revision >= floor else {
                    throw ActivityFailure("STALE_REVISION", "The revision is older than the current activity state.")
                }
                if revision == floor, revision != current || content.snapshot != activity.snapshot {
                    throw ActivityFailure("CONFLICT", "This revision already contains different state.")
                }
                try content.check(activity)
                let result = try await self.backend.end(activity.with(snapshot: content.snapshot, state: activity.state), policy)
                try self.remember(result)
                return result.record
            }
            // A redacted receipt read after a restart knows the accepted revision only by its digest. While ActivityKit
            // still shows an older revision, ending with that snapshot would publish it again, so the activity ends
            // without new content and the tombstone keeps the accepted revision.
            if let receipt = self.receipts.first(where: { $0.id == id }), receipt.snapshot == nil,
               receipt.entry.revision > Activity.revision(of: activity.snapshot) {
                let ended = try await self.backend.endKeepingContent(activity, policy)
                let entry = receipt.entry
                try self.remember(Receipt(entry: StoredReceipt(id: id, summary: entry.summary, state: ended.state, revision: entry.revision,
                                                               content: entry.content)))
                return ended.record
            }
            let result = try await self.backend.end(activity, policy)
            try self.remember(result)
            return result.record
        }
    }

    func list() async throws -> [Activity.Record] {
        try await queue.run {
            try self.load()
            return await self.observed().map(\.record)
        }
    }

    private func active(_ id: String) async throws -> Activity {
        guard !receipts.contains(where: { $0.id == id && isTerminal($0.state) }),
              let activity = await observed().first(where: { $0.id == id }),
              isLive(activity.state) else {
            throw ActivityFailure("NOT_FOUND", "The active activity was not found.")
        }
        return activity
    }
}

@MainActor
public final class LiveActivityController {
    private let lifecycle: ActivityLifecycle<NativeActivity>
    /// Keeps receipts in a custom store of v1 activities, or only in memory.
    public init(backend: ActivityBackend, store: ActivityReceiptStore? = nil) {
        lifecycle = ActivityLifecycle(backend: LifecycleBackend(backend), storage: store.map { .custom($0) } ?? .memory())
    }
    /// Keeps receipts in the shared receipt file.
    public init(backend: ActivityBackend, store: FileReceiptStore) {
        lifecycle = ActivityLifecycle(backend: LifecycleBackend(backend), storage: .file(store))
    }

    public func start(_ request: StartRequest) async throws -> ActivityRecord {
        try request.validate()
        return try await lifecycle.start(key: request.activityKey, fingerprint: request.fingerprint, snapshot: request.snapshot) { id in
            let attributes = try LiveActivityAttributes(request: request, instanceID: id)
            try PayloadLimit.check(attributes: attributes, snapshot: request.snapshot)
            return attributes
        }
    }

    public func update(_ request: UpdateRequest) async throws -> ActivityRecord {
        try await lifecycle.update(id: request.id, snapshot: request.snapshot,
            validate: { try request.snapshot.validate(template: $0.attributes.template) },
            check: { try PayloadLimit.check(attributes: $0.attributes, snapshot: request.snapshot) })
    }

    public func end(_ request: EndRequest) async throws -> ActivityRecord {
        try await lifecycle.end(id: request.id, policy: request.policy)
    }

    public func list() async throws -> [ActivityRecord] {
        try await lifecycle.list()
    }
}
