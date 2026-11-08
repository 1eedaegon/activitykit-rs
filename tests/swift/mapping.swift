import Foundation

/// A source of authorization changes that ends its stream when it is released, as a temporary
/// `ActivityAuthorizationInfo` might.
final class FakeAuthorizationSource: AuthorizationSource, @unchecked Sendable {
    private var continuation: AsyncStream<Bool>.Continuation?
    let updates: AsyncStream<Bool>
    init() {
        var held: AsyncStream<Bool>.Continuation?
        updates = AsyncStream { held = $0 }
        continuation = held
    }
    deinit { continuation?.finish() }
    func send(_ enabled: Bool) { continuation?.yield(enabled) }
}

final class ReplyLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [AuthorizationReply] = []
    func append(_ reply: AuthorizationReply) { lock.lock(); entries.append(reply); lock.unlock() }
    var replies: [AuthorizationReply] { lock.lock(); defer { lock.unlock() }; return entries }
}

extension LifecycleTests {
    @MainActor static func testActivityKitMapping() async throws {
        testErrorTable()
        try testFailureMembers()
        try await testAuthorizationWatcher()
        try testSnapshotTimestamps()
        try await testEndWithFinalContent()
    }

    // AK-ERROR-4, AK-START-8, AK-START-10
    /// Every `ActivityAuthorizationError` case of the iOS 26.2 SDK, by name, to its code; the message names the case.
    @MainActor static func testErrorTable() {
        let expected: [(String, String, String?)] = [
            ("attributesTooLarge", "PAYLOAD_TOO_LARGE", nil), ("unsupported", "UNSUPPORTED_PLATFORM", nil),
            ("denied", "PERMISSION_DENIED", nil), ("globalMaximumExceeded", "SYSTEM_LIMIT", "device"),
            ("targetMaximumExceeded", "SYSTEM_LIMIT", "app"), ("unsupportedTarget", "CONFIGURATION_REQUIRED", nil),
            ("visibility", "NOT_FOREGROUND", nil), ("persistenceFailure", "NATIVE_ERROR", nil),
            ("missingProcessIdentifier", "NATIVE_ERROR", nil), ("unentitled", "CONFIGURATION_REQUIRED", nil),
            ("malformedActivityIdentifier", "NATIVE_ERROR", nil), ("reconnectNotPermitted", "NATIVE_ERROR", nil),
        ]
        for (name, code, scope) in expected {
            let failure = ActivityKitErrors.failure(for: name)
            expect(failure.code == code && failure.scope == scope && failure.message.contains(name),
                   "\(name) is \(code) \(scope ?? ""), got \(failure.code) \(failure.scope ?? "") \(failure.message)")
        }
        let unknown = ActivityKitErrors.failure(for: "somethingNew")
        expect(unknown.code == "NATIVE_ERROR" && unknown.message.contains("somethingNew"), "a case this version does not know is NATIVE_ERROR")
    }

    // AK-ERROR-3, AK-ERROR-4
    /// `SYSTEM_LIMIT` says whose limit, `UNSUPPORTED_FEATURE` which feature needs which iOS; other codes have neither.
    @MainActor static func testFailureMembers() throws {
        func object(_ failure: ActivityFailure) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(failure)) as? NSDictionary ?? [:]
        }
        let limit = try object(.systemLimit(scope: "app", case: "targetMaximumExceeded"))
        expect(limit["scope"] as? String == "app", "a limit names its scope")
        let feature = try object(.unsupportedFeature("transient", minimumIos: "18.0"))
        expect(feature["feature"] as? String == "transient" && feature["minimumIos"] as? String == "18.0", "a feature names the iOS it needs")
        let plain = try object(ActivityFailure("INVALID_INPUT", "x"))
        expect(plain == ["code": "INVALID_INPUT", "message": "x"], "other failures have code and message only")
    }

    // AK-AUTH-3, AK-AUTH-5
    /// The watcher holds its source for as long as it watches, and reports every change as the whole authorization.
    @MainActor static func testAuthorizationWatcher() async throws {
        let log = ReplyLog()
        weak var held: FakeAuthorizationSource?
        var watcher: AuthorizationWatcher? = {
            let source = FakeAuthorizationSource()
            held = source
            return AuthorizationWatcher(source: source, read: { AuthorizationReply(supported: true, enabled: $0, buttons: true) },
                                        emit: { log.append($0) })
        }()
        watcher?.start()
        // Nothing else holds the source: it lives because the watcher holds it.
        expect(held != nil, "the watcher keeps its source alive")
        held?.send(false)
        held?.send(true)
        await verify(await eventually { log.replies.count == 2 }, "each change arrives")
        expect(log.replies == [AuthorizationReply(supported: true, enabled: false, buttons: true),
                               AuthorizationReply(supported: true, enabled: true, buttons: true)], "as the whole authorization, in order")
        watcher = nil
        await verify(await eventually { held == nil }, "a released watcher lets its source go")
        // A released watcher reports nothing more, also while its source lives on.
        let kept = FakeAuthorizationSource()
        var second: AuthorizationWatcher? = AuthorizationWatcher(source: kept, read: { AuthorizationReply(supported: true, enabled: $0, buttons: true) },
                                                                 emit: { log.append($0) })
        second?.start()
        kept.send(false)
        await verify(await eventually { log.replies.count == 3 }, "a second watcher reports")
        second = nil
        try await Task.sleep(nanoseconds: 50_000_000)
        kept.send(true)
        try await Task.sleep(nanoseconds: 100_000_000)
        expect(log.replies.count == 3 && second == nil, "a released watcher reports nothing more")
    }

    // AK-UPDATE-11
    /// A snapshot may carry the time its content was made, in epoch milliseconds.
    @MainActor static func testSnapshotTimestamps() throws {
        let decoder = JSONDecoder()
        let snapshot = try decoder.decode(LayoutSnapshot.self, from: Data(#"{"revision":1,"values":{},"timestamp":1790000000000}"#.utf8))
        expect(snapshot.timestamp == 1_790_000_000_000, "the timestamp is read")
        try snapshot.validate()
        for text in [#"{"revision":1,"values":{},"timestamp":-1}"#, #"{"revision":1,"values":{},"timestamp":8640000000000001}"#] {
            let invalid = try decoder.decode(LayoutSnapshot.self, from: Data(text.utf8))
            do { try invalid.validate(); expect(false, "rejects \(text)") } catch let failure as ActivityFailure {
                expect(failure.code == "INVALID_INPUT", "a timestamp outside 0...8640000000000000 is INVALID_INPUT")
            }
        }
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? NSDictionary
        expect(encoded?["timestamp"] as? Int == 1_790_000_000_000, "it is written back")
    }

    // AK-END-6
    /// The lifecycle ends with final content under the rules of an update, and keeps the receipts.
    @MainActor static func testEndWithFinalContent() async throws {
        let backend = FakeLayoutBackend()
        let controller = LayoutActivityController(backend: backend)
        let first = try await controller.start(meterRequest("end:1"))
        let final = LayoutSnapshot(revision: 1, values: ["title": .string("Done"), "progress": .number(1)], timestamp: 5)
        let ended = try await controller.end(LayoutEndRequest(id: first.id, policy: EndPolicy(kind: "immediate", at: nil), snapshot: final))
        expect(ended.state == "ended" && ended.snapshot == final && backend.ends == ["end 1"], "the activity ends showing its final content")
        let again = try await controller.end(LayoutEndRequest(id: first.id, policy: EndPolicy(kind: "immediate", at: nil), snapshot: final))
        expect(again.snapshot == final && backend.ends.count == 1, "ending again answers the ended record")
        let second = try await controller.start(meterRequest("end:2"))
        _ = try await controller.update(layoutUpdate(second.id, meter(2, 0.5)))
        await expectError("STALE_REVISION") {
            _ = try await controller.end(LayoutEndRequest(id: second.id, policy: EndPolicy(kind: "default", at: nil), snapshot: meter(1, 0.9)))
        }
        await expectError("CONFLICT") {
            _ = try await controller.end(LayoutEndRequest(id: second.id, policy: EndPolicy(kind: "default", at: nil), snapshot: meter(2, 0.9)))
        }
        let typed = LayoutSnapshot(revision: 3, values: ["title": .number(1), "progress": .number(1)])
        await expectError("INVALID_INPUT") {
            _ = try await controller.end(LayoutEndRequest(id: second.id, policy: EndPolicy(kind: "default", at: nil), snapshot: typed))
        }
        let same = try await controller.end(LayoutEndRequest(id: second.id, policy: EndPolicy(kind: "default", at: nil), snapshot: meter(2, 0.5)))
        expect(same.state == "ended" && same.snapshot.revision == 2, "the shown content again ends the activity with it")
    }
}
