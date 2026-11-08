import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif
#if canImport(ActivityKitCore)
import ActivityKitCore
#endif

// The C functions that the activitykit crate calls (src/native.rs). Each one takes JSON and answers through a C
// callback with the caller's context: `{"ok":true,"data":…}` or `{"ok":false,"error":{"code","message"}}`. A request
// is copied before the function returns, so the caller may free it; the reply's bytes live only during the callback.
// Any thread may call any function. `ak_authorization` and `ak_image_folder` reply before they return; the others
// reply once, later, from the main thread.

/// The reply callback: the caller's context, then the reply's bytes and their count.
public typealias AKReply = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> Void
/// The event callback: one event as JSON, from any thread.
public typealias AKEventHandler = @convention(c) (UnsafePointer<UInt8>?, Int) -> Void

/// Where one reply goes.
struct ReplyTarget: @unchecked Sendable {
    let context: UnsafeMutableRawPointer?
    let function: AKReply

    func send(_ data: Data) {
        data.withUnsafeBytes { function(context, $0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    }
}

private func copy(_ bytes: UnsafePointer<UInt8>?, _ count: Int) -> Data {
    guard let bytes, count > 0 else { return Data() }
    return Data(bytes: bytes, count: count)
}

/// Runs `operation` on the main actor and sends its reply.
private func answer(_ context: UnsafeMutableRawPointer?, _ reply: AKReply, _ operation: @escaping @MainActor () async -> Data) {
    let target = ReplyTarget(context: context, function: reply)
    _ = Relay.shared
    Task { @MainActor in target.send(await operation()) }
}

@_cdecl("ak_start")
public func ak_start(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ context: UnsafeMutableRawPointer?, _ reply: AKReply) {
    let request = copy(bytes, count)
    answer(context, reply) { await Bridge.shared.start(request) }
}

@_cdecl("ak_update")
public func ak_update(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ context: UnsafeMutableRawPointer?, _ reply: AKReply) {
    let request = copy(bytes, count)
    answer(context, reply) { await Bridge.shared.update(request) }
}

@_cdecl("ak_end")
public func ak_end(_ bytes: UnsafePointer<UInt8>?, _ count: Int, _ context: UnsafeMutableRawPointer?, _ reply: AKReply) {
    let request = copy(bytes, count)
    answer(context, reply) { await Bridge.shared.end(request) }
}

@_cdecl("ak_list")
public func ak_list(_ context: UnsafeMutableRawPointer?, _ reply: AKReply) {
    answer(context, reply) { await Bridge.shared.list() }
}

@_cdecl("ak_authorization")
public func ak_authorization(_ context: UnsafeMutableRawPointer?, _ reply: AKReply) {
    ReplyTarget(context: context, function: reply).send(Bridge.encode(Success(data: Systems.current.authorization())))
}

@_cdecl("ak_image_folder")
public func ak_image_folder(_ context: UnsafeMutableRawPointer?, _ reply: AKReply) {
    let data: Data
    do { data = Bridge.encode(Success(data: ImageFolderReply(path: try Systems.current.imageFolder().path))) }
    catch { data = Bridge.encode(Failure(error)) }
    ReplyTarget(context: context, function: reply).send(data)
}

/// Sets the event handler, replacing an earlier one; nil drops events from then on. The first handler starts the
/// observation of states and of the authorization, and every handler gets the button taps that waited for it.
@_cdecl("ak_set_event_handler")
public func ak_set_event_handler(_ handler: AKEventHandler?) {
    let first = EventSink.shared.set(handler)
    Relay.shared.register { EventSink.shared.emit(.action($0)) }
    if first { Systems.current.observe(EventSink.shared) }
}

/// The relay of button taps, observing from the first call of the bridge.
enum Relay {
    static let shared = ActionRelay { Systems.current.activityKey(of: $0) }
}

/// The C event handler and the events it gets.
final class EventSink: @unchecked Sendable {
    static let shared = EventSink()
    private let lock = NSLock()
    private var handler: AKEventHandler?
    private var registered = false

    /// Whether this is the first handler.
    func set(_ handler: AKEventHandler?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        let first = !registered && handler != nil
        registered = registered || handler != nil
        return first
    }

    /// Calls the handler on this thread. For a tap, the handler returns once the app has taken it.
    func emit(_ event: BridgeEvent) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        guard let handler, let data = try? JSONEncoder().encode(event) else { return }
        data.withUnsafeBytes { handler($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    }
}

/// An event as Rust reads it: `{"type":"action"|"state"|"authorization", …}`.
enum BridgeEvent: Encodable {
    case started(activityId: String, activityKey: String)
    case action(LiveActivityAction)
    case state(activityId: String, activityKey: String, state: String)
    case authorization(AuthorizationReply)

    private enum Keys: String, CodingKey { case type, activityId, actionId, activityKey, state, authorization }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case let .started(activityId, activityKey):
            try container.encode("started", forKey: .type)
            try container.encode(activityId, forKey: .activityId)
            try container.encode(activityKey, forKey: .activityKey)
        case .action(let action):
            try container.encode("action", forKey: .type)
            try container.encode(action.activityId, forKey: .activityId)
            try container.encode(action.actionId, forKey: .actionId)
            try container.encodeIfPresent(action.activityKey, forKey: .activityKey)
        case let .state(activityId, activityKey, state):
            try container.encode("state", forKey: .type)
            try container.encode(activityId, forKey: .activityId)
            try container.encode(activityKey, forKey: .activityKey)
            try container.encode(state, forKey: .state)
        case .authorization(let authorization):
            try container.encode("authorization", forKey: .type)
            try container.encode(authorization, forKey: .authorization)
        }
    }
}

/// The alert of an update, beside the contract request.
struct AlertText: Codable, Equatable, Sendable {
    let title: String
    let body: String
}

/// `ak_start`: the contract's `start_layout` request and the relevance ActivityKit takes beside it.
private struct StartCall: Decodable {
    let request: LayoutRequest
    let relevance: Double?
}

/// `ak_update`: the contract's `update_layout` request, a relevance and an alert.
private struct UpdateCall: Decodable {
    let request: LayoutUpdateRequest
    let relevance: Double?
    let alert: AlertText?
}

/// `ak_end`: the contract's `end_layout` request and the relevance of its final content.
private struct EndCall: Decodable {
    let request: LayoutEndRequest
    let relevance: Double?
}

private struct ImageFolderReply: Encodable {
    let path: String
}

/// The requests of Rust on the main actor, through one layout controller with its receipts.
@MainActor
final class Bridge {
    static let shared = Bridge()
    nonisolated static let unsupported = ActivityFailure("UNSUPPORTED_PLATFORM", "Live Activities require iPhone with iOS 16.2 or iPad with iPadOS 17 or later.")

    let presentations = Presentations()
    private var controller: LayoutActivityController?

    /// Forgets the controller, so the next call creates one from the current system. For the tests.
    func reset() { controller = nil }

    func start(_ data: Data) async -> Data {
        await reply {
            let call = try JSONDecoder().decode(StartCall.self, from: data)
            let key = call.request.activityKey
            self.presentations.expectStart(key: key, relevance: call.relevance)
            defer { self.presentations.forgetStart(key: key) }
            return try await self.lifecycle().start(call.request)
        }
    }

    func update(_ data: Data) async -> Data {
        await reply {
            let call = try JSONDecoder().decode(UpdateCall.self, from: data)
            let (id, revision) = (call.request.id, call.request.snapshot.revision)
            self.presentations.expectUpdate(id: id, revision: revision, relevance: call.relevance, alert: call.alert)
            defer { self.presentations.forgetUpdate(id: id, revision: revision) }
            return try await self.lifecycle().update(call.request)
        }
    }

    func end(_ data: Data) async -> Data {
        await reply {
            let call = try JSONDecoder().decode(EndCall.self, from: data)
            let id = call.request.id
            self.presentations.expectEnd(id: id, relevance: call.relevance)
            defer { self.presentations.forgetEnd(id: id) }
            return try await self.lifecycle().end(call.request)
        }
    }

    func list() async -> Data {
        await reply { try await self.lifecycle().list() }
    }

    private func lifecycle() throws -> LayoutActivityController {
        if let controller { return controller }
        let created = try Systems.current.makeController(presentations: presentations, events: .shared)
        controller = created
        return created
    }

    /// The reply of `operation`, after the platform check that comes before every command.
    private func reply<Value: Encodable>(_ operation: () async throws -> Value) async -> Data {
        do {
            guard Systems.current.authorization().supported else { throw Bridge.unsupported }
            return Bridge.encode(Success(data: try await operation()))
        } catch {
            return Bridge.encode(Failure(error))
        }
    }

    nonisolated static func encode<Value: Encodable>(_ value: Value) -> Data {
        (try? JSONEncoder().encode(value))
            ?? Data(#"{"ok":false,"error":{"code":"NATIVE_ERROR","message":"The reply could not be encoded."}}"#.utf8)
    }
}
