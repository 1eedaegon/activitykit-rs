import Foundation
import CryptoKit
#if os(iOS)
import ActivityKit
#endif

public struct ActivityTimer: Codable, Hashable, Sendable {
    public let startedAt: Int64
    public let endsAt: Int64
    public init(startedAt: Int64, endsAt: Int64) { self.startedAt = startedAt; self.endsAt = endsAt }
}

public struct ActivitySnapshot: Codable, Hashable, Sendable {
    public let revision: Int64
    public let title: String
    public let status: String
    public let progress: Double?
    public let timer: ActivityTimer?
    public let staleAt: Int64?
    public init(revision: Int64, title: String, status: String, progress: Double?, timer: ActivityTimer?, staleAt: Int64?) {
        self.revision = revision; self.title = title; self.status = status
        self.progress = progress; self.timer = timer; self.staleAt = staleAt
    }

    /// Match the wire contract: a reused revision must contain the same encoded text.
    /// Swift's default String equality treats canonically equivalent Unicode as identical.
    public static func == (lhs: ActivitySnapshot, rhs: ActivitySnapshot) -> Bool {
        lhs.revision == rhs.revision && lhs.title.utf8.elementsEqual(rhs.title.utf8)
            && lhs.status.utf8.elementsEqual(rhs.status.utf8) && lhs.progress == rhs.progress
            && lhs.timer == rhs.timer && lhs.staleAt == rhs.staleAt
    }
}

public struct StartRequest: Codable, Equatable, Sendable {
    public let activityKey: String
    public let schemaVersion: Int
    public let template: String
    public let fallback: String
    public let snapshot: ActivitySnapshot
    public init(activityKey: String, schemaVersion: Int, template: String, fallback: String, snapshot: ActivitySnapshot) {
        self.activityKey = activityKey; self.schemaVersion = schemaVersion; self.template = template
        self.fallback = fallback; self.snapshot = snapshot
    }
    public func fingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LiveActivityAttributes: Codable, Sendable {
    public typealias ContentState = ActivitySnapshot
    public let instanceID: String
    public let activityKey: String
    public let schemaVersion: Int
    public let template: String
    public let fallback: String
    public let initialFingerprint: String
    public init(request: StartRequest, instanceID: String) throws {
        self.instanceID = instanceID; self.activityKey = request.activityKey
        self.schemaVersion = request.schemaVersion; self.template = request.template
        self.fallback = request.fallback; self.initialFingerprint = try request.fingerprint()
    }
}

#if os(iOS)
@available(iOS 16.1, *)
extension LiveActivityAttributes: ActivityAttributes {}
#endif

public struct UpdateRequest: Codable, Sendable {
    public let id: String
    public let snapshot: ActivitySnapshot
    public init(id: String, snapshot: ActivitySnapshot) { self.id = id; self.snapshot = snapshot }
}

public struct EndPolicy: Codable, Sendable {
    public let kind: String
    public let at: Int64?
    public init(kind: String, at: Int64?) { self.kind = kind; self.at = at }
}

public struct EndRequest: Codable, Sendable {
    public let id: String
    public let policy: EndPolicy
    public init(id: String, policy: EndPolicy) { self.id = id; self.policy = policy }
}

public struct ActivityFailure: Error, Codable, Sendable {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
}
