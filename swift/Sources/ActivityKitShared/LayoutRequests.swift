import Foundation
import CryptoKit
#if os(iOS)
import ActivityKit
#endif

/// Android-only options of a layout start. iOS checks and then ignores them.
public struct LayoutAndroidOptions: Codable, Sendable {
    public enum Visibility: String, Codable, Sendable { case `public`, `private`, secret }
    public let visibility: Visibility
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        visibility = try object.need("visibility")
        try object.finish()
    }
}

/// What a start asks ActivityKit for: a push token of the activity's own (`"token"`), or a broadcast channel
/// (`{"channel": "<id>"}`, iOS 18).
public enum LayoutPush: Codable, Equatable, Sendable {
    case token
    case channel(String)
    private enum Key: String, CodingKey { case channel }
    public init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            guard name == "token" else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown push \(name)."))
            }
            self = .token
            return
        }
        var object = try LayoutReader(decoder)
        self = .channel(try object.need("channel"))
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .token:
            var single = encoder.singleValueContainer()
            try single.encode("token")
        case .channel(let id):
            var object = encoder.container(keyedBy: Key.self)
            try object.encode(id, forKey: .channel)
        }
    }
}

/// The input of `start_layout`.
public struct LayoutRequest: Codable, Sendable {
    public let activityKey: String
    public let schemaVersion: Int
    public let fallback: String
    public let layout: LayoutRegions
    public let styles: [String: LayoutStyle]?
    public let snapshot: LayoutSnapshot
    public let android: LayoutAndroidOptions?
    /// What the activity asks for; absent, nothing. Not part of the fingerprint: a repeated keyed start is the same
    /// activity whatever it asks for.
    public let push: LayoutPush?

    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        activityKey = try object.need("activityKey"); schemaVersion = try object.need("schemaVersion")
        fallback = try object.need("fallback"); layout = try object.need("layout"); styles = try object.take("styles")
        snapshot = try object.need("snapshot"); android = try object.take("android"); push = try object.take("push")
        try object.finish()
    }
    public var document: LayoutDocument { LayoutDocument(layout: layout, styles: styles) }
    /// Payload weight of the layout, the style table and the values.
    public var weight: Int { document.weight + snapshot.values.wireWeight }
    /// The SHA-256 of the request without its snapshot's timestamp, which differs for every start of the same content.
    public func fingerprint() throws -> String {
        struct Body: Encodable {
            let activityKey: String, schemaVersion: Int, fallback: String, layout: LayoutRegions, styles: [String: LayoutStyle]?
            let snapshot: LayoutSnapshot, android: LayoutAndroidOptions?
        }
        let body = Body(activityKey: activityKey, schemaVersion: schemaVersion, fallback: fallback, layout: layout, styles: styles,
                        snapshot: snapshot.content, android: android)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(body)).map { String(format: "%02x", $0) }.joined()
    }
}

/// The input of `update_layout`: the values replace the whole map.
public struct LayoutUpdateRequest: Codable, Sendable {
    public let id: String
    public let snapshot: LayoutSnapshot
    public init(id: String, snapshot: LayoutSnapshot) { self.id = id; self.snapshot = snapshot }
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        id = try object.need("id"); snapshot = try object.need("snapshot")
        try object.finish()
    }
    /// Payload weight of the values.
    public var weight: Int { snapshot.values.wireWeight }
}

/// The input of `end_layout`: the handle, the dismissal policy and, optionally, the final content.
public struct LayoutEndRequest: Codable, Sendable {
    private struct Policy: Decodable {
        let kind: String
        let at: Int64?
        init(from decoder: Decoder) throws {
            var object = try LayoutReader(decoder)
            kind = try object.need("kind"); at = try object.take("at")
            try object.finish()
        }
    }
    public let id: String
    public let policy: EndPolicy
    /// Checked like an update; without it the activity ends showing its last accepted content.
    public let snapshot: LayoutSnapshot?
    public init(id: String, policy: EndPolicy, snapshot: LayoutSnapshot? = nil) { self.id = id; self.policy = policy; self.snapshot = snapshot }
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        id = try object.need("id")
        let strict: Policy = try object.need("policy")
        policy = EndPolicy(kind: strict.kind, at: strict.at)
        snapshot = try object.take("snapshot")
        try object.finish()
    }
}

/// ActivityKit attributes of a layout activity. The content state is the snapshot.
public struct LiveActivityLayoutAttributes: Codable, Sendable {
    public typealias ContentState = LayoutSnapshot
    public let instanceID: String
    public let activityKey: String
    public let schemaVersion: Int
    public let fallback: String
    public let initialFingerprint: String
    public let document: LayoutDocument
    public init(request: LayoutRequest, instanceID: String) throws {
        self.instanceID = instanceID; self.activityKey = request.activityKey
        self.schemaVersion = request.schemaVersion; self.fallback = request.fallback
        self.initialFingerprint = try request.fingerprint(); self.document = request.document
    }
}

#if os(iOS)
@available(iOS 16.1, *)
extension LiveActivityLayoutAttributes: ActivityAttributes {}
#endif

private struct LayoutPayload: Encodable {
    let attributes: LiveActivityLayoutAttributes
    let contentState: LayoutSnapshot
}
extension PayloadLimit {
    public static func check(attributes: LiveActivityLayoutAttributes, snapshot: LayoutSnapshot) throws {
        let data = try JSONEncoder().encode(LayoutPayload(attributes: attributes, contentState: snapshot))
        guard data.count <= bytes else {
            throw ActivityFailure("PAYLOAD_TOO_LARGE", "Activity attributes and state exceed 4 KB.")
        }
    }
}
