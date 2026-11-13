import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

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

/// What the lifecycle needs from an activity of the contract.
protocol LifecycleActivity: Sendable {
    associatedtype Attributes
    associatedtype Snapshot: Equatable & Encodable & Sendable
    associatedtype Record
    static var schemaVersion: Int { get }
    static var instancePrefix: String { get }
    static func content(_ snapshot: Snapshot) -> StoredReceipt.Content
    static func snapshot(in content: StoredReceipt.Content) -> Snapshot?
    static func revision(of snapshot: Snapshot) -> Int64
    /// Whether two snapshots hold the same content: when they were made does not count.
    static func sameContent(_ one: Snapshot, _ other: Snapshot) -> Bool
    /// The digest a redacted receipt keeps of a snapshot's content.
    static func digest(of snapshot: Snapshot) throws -> String
    /// The record of an activity that only its receipt knows; a redacted receipt shows an empty snapshot.
    static func record(_ entry: StoredReceipt) -> Record
    var id: String { get }
    var state: String { get }
    var snapshot: Snapshot { get }
    var summary: ReceiptSummary { get }
    var record: Record { get }
    func with(snapshot: Snapshot, state: String) -> Self
}

/// The system calls the lifecycle makes.
struct LifecycleBackend<Activity: LifecycleActivity> {
    let preflight: @MainActor () throws -> Void
    let list: @MainActor () async -> [Activity]
    let start: @MainActor (Activity.Attributes, Activity.Snapshot) async throws -> Activity
    let update: @MainActor (Activity, Activity.Snapshot) async throws -> Activity
    let end: @MainActor (Activity, EndPolicy) async throws -> Activity
    /// Ends without new content: the system keeps what it last published.
    let endKeepingContent: @MainActor (Activity, EndPolicy) async throws -> Activity
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

/// An activity that holds its key and can be ended: also one that waits for its scheduled start, which takes no
/// update until it began.
private func isLive(_ state: String) -> Bool { ["active", "stale", "pending"].contains(state) }
private func isTerminal(_ state: String) -> Bool { ["ended", "dismissed"].contains(state) }

/// The rules of the lifecycle: idempotent start by fingerprint, revisions, tombstones and receipts.
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
            // ActivityKit takes an update of an activity that waits for its scheduled start, without an error, and
            // then begins it with the content of its start: the update would be accepted here and never shown.
            guard activity.state != "pending" else {
                throw ActivityFailure("CONFLICT", "The activity has not started yet; update it once it is active.")
            }
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
                    guard Activity.sameContent(snapshot, activity.snapshot) else { throw conflict }
                    return activity.record
                }
                guard case .digest(let digest)? = receipt?.entry.content, digest == (try Activity.digest(of: snapshot)) else { throw conflict }
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
                if revision == floor, revision != current || !Activity.sameContent(content.snapshot, activity.snapshot) {
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
