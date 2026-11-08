import Foundation

@MainActor
final class FakeBackend: ActivityBackend {
    var activities: [NativeActivity] = []
    var starts = 0
    var updates = 0
    var failUpdate = false
    var delayObservation = false
    var startError: ActivityFailure?
    func preflightStart() throws { if let error = startError { throw error } }
    func list() async -> [NativeActivity] { activities }
    func start(_ attributes: LiveActivityAttributes, snapshot: ActivitySnapshot) async throws -> NativeActivity {
        starts += 1
        let activity = NativeActivity(id: UUID().uuidString, attributes: attributes, snapshot: snapshot, state: "active")
        activities.append(activity)
        return activity
    }
    func update(_ activity: NativeActivity, snapshot: ActivitySnapshot) async throws -> NativeActivity {
        updates += 1
        await Task.yield()
        if failUpdate { throw ActivityFailure("NATIVE_ERROR", "update failed") }
        let next = NativeActivity(id: activity.id, attributes: activity.attributes, snapshot: snapshot, state: "active")
        if !delayObservation { activities = activities.map { $0.id == activity.id ? next : $0 } }
        return next
    }
    func end(_ activity: NativeActivity, policy: EndPolicy) async throws -> NativeActivity {
        let next = NativeActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended")
        activities = activities.filter { $0.id != activity.id }
        return next
    }
}

@main
struct LifecycleTests {
    static var assertions = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(label)") }
    }
    @MainActor static func expectError(_ code: String, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected \(code)") }
        catch let error as ActivityFailure { expect(error.code == code, "error code \(code), got \(error.code)") }
        catch { fatalError("Unexpected error \(error)") }
    }
    static func snapshot(_ revision: Int64 = 0, _ progress: Double = 0) -> ActivitySnapshot {
        ActivitySnapshot(revision: revision, title: "Download", status: "Working", progress: progress, timer: nil, staleAt: nil)
    }
    static func request(_ key: String = "job:1", _ state: ActivitySnapshot = snapshot()) -> StartRequest {
        StartRequest(activityKey: key, schemaVersion: 1, template: "progress", fallback: "none", snapshot: state)
    }
    @MainActor static func main() async throws {
        let backend = FakeBackend()
        let controller = LiveActivityController(backend: backend)
        let first = try await controller.start(request())
        expect(first.activityKey == "job:1", "start preserves key")
        let duplicate = try await controller.start(request())
        expect(first.id == duplicate.id && backend.starts == 1, "duplicate start is idempotent")
        await expectError("CONFLICT") { _ = try await controller.start(request("job:1", snapshot(0, 0.3))) }
        let updated = try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(2, 0.5)))
        expect(updated.snapshot.revision == 2, "update applies snapshot")
        _ = try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(2, 0.5)))
        expect(backend.updates == 1, "same revision same data does not call native")
        await expectError("STALE_REVISION") { _ = try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(1))) }
        await expectError("CONFLICT") { _ = try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(2, 0.6))) }
        let timer = ActivitySnapshot(revision: 3, title: "Timer", status: "Working", progress: nil, timer: ActivityTimer(startedAt: 0, endsAt: 10), staleAt: nil)
        await expectError("INVALID_INPUT") { _ = try await controller.update(UpdateRequest(id: first.id, snapshot: timer)) }
        backend.failUpdate = true
        await expectError("NATIVE_ERROR") { _ = try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(3))) }
        backend.failUpdate = false
        let recovered = LiveActivityController(backend: backend)
        let recoveredList = try await recovered.list()
        expect(recoveredList.count == 1 && recoveredList[0].snapshot.revision == 2, "restart reads OS state")
        let again = try await recovered.start(request())
        expect(again.id == first.id, "restart preserves duplicate-start fingerprint")
        let a = Task { try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(3, 0.7))) }
        while backend.updates < 3 { await Task.yield() }
        let b = Task { try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(4, 0.8))) }
        _ = try await a.value
        _ = try await b.value
        let afterConcurrent = try await controller.list()
        expect(afterConcurrent.first?.snapshot.revision == 4, "concurrent updates serialize across suspension")
        await expectError("INVALID_INPUT") { _ = try await controller.end(EndRequest(id: first.id, policy: EndPolicy(kind: "after", at: 0))) }
        let ended = try await controller.end(EndRequest(id: first.id, policy: EndPolicy(kind: "immediate", at: nil)))
        expect(ended.state == "ended", "end result")
        let endedAgain = try await controller.end(EndRequest(id: first.id, policy: EndPolicy(kind: "immediate", at: nil)))
        expect(ended.id == endedAgain.id, "known end idempotent")
        await expectError("NOT_FOUND") { _ = try await controller.end(EndRequest(id: "unknown", policy: EndPolicy(kind: "immediate", at: nil))) }
        await expectError("NOT_FOUND") { _ = try await controller.update(UpdateRequest(id: first.id, snapshot: snapshot(5))) }
        let newActivity = try await controller.start(request())
        expect(newActivity.id != first.id, "new generation never reuses handle")
        backend.activities = []
        let disappeared = try await controller.list()
        expect(disappeared.allSatisfy { $0.state != "active" }, "missing OS activity never reported active")
        backend.startError = ActivityFailure("PERMISSION_DENIED", "disabled")
        await expectError("PERMISSION_DENIED") { _ = try await controller.start(request("disabled")) }
        let overlarge = ActivitySnapshot(revision: 0, title: String(repeating: "a", count: 6000), status: "ok", progress: 0, timer: nil, staleAt: nil)
        await expectError("PAYLOAD_TOO_LARGE") { try PayloadLimit.check(attributes: LiveActivityAttributes(request: request(), instanceID: "x"), snapshot: overlarge) }
        try snapshot().validate(template: "progress")
        await expectError("INVALID_INPUT") { try ActivitySnapshot(revision: -1, title: "x", status: "y", progress: 0, timer: nil, staleAt: nil).validate(template: "progress") }
        await expectError("INVALID_INPUT") { try ActivitySnapshot(revision: 1, title: "  ", status: "y", progress: 0, timer: nil, staleAt: nil).validate(template: "progress") }
        await expectError("INVALID_INPUT") { try ActivitySnapshot(revision: 1, title: "x", status: "y", progress: .nan, timer: nil, staleAt: nil).validate(template: "progress") }
        await expectError("INVALID_INPUT") { try ActivitySnapshot(revision: 1, title: "x", status: "y", progress: nil, timer: ActivityTimer(startedAt: 20, endsAt: 10), staleAt: nil).validate(template: "timer") }
        let receiptURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("receipts.json")
        defer { try? FileManager.default.removeItem(at: receiptURL.deletingLastPathComponent()) }
        let lagging = FakeBackend()
        lagging.delayObservation = true
        let persistent = LiveActivityController(backend: lagging, store: FileReceiptStore(url: receiptURL))
        let lagStart = try await persistent.start(request("lag"))
        _ = try await persistent.update(UpdateRequest(id: lagStart.id, snapshot: snapshot(2, 0.5)))
        let restart = LiveActivityController(backend: lagging, store: FileReceiptStore(url: receiptURL))
        let restartState = try await restart.list()
        expect(restartState[0].snapshot.revision == 2, "durable receipt preserves accepted state while OS publication lags")
        await expectError("STALE_REVISION") { _ = try await restart.update(UpdateRequest(id: lagStart.id, snapshot: snapshot(1))) }
        _ = try await restart.end(EndRequest(id: lagStart.id, policy: EndPolicy(kind: "immediate", at: nil)))
        let afterRestartEnd = LiveActivityController(backend: lagging, store: FileReceiptStore(url: receiptURL))
        let repeatedEnd = try await afterRestartEnd.end(EndRequest(id: lagStart.id, policy: EndPolicy(kind: "immediate", at: nil)))
        expect(repeatedEnd.state == "ended", "ended receipt survives process restart")
        await expectError("NOT_FOUND") { _ = try await afterRestartEnd.update(UpdateRequest(id: lagStart.id, snapshot: snapshot(3))) }
        let corruptURL = receiptURL.deletingLastPathComponent().appendingPathComponent("corrupt.json")
        try Data("invalid JSON".utf8).write(to: corruptURL)
        await expectError("NATIVE_ERROR") { _ = try FileReceiptStore(url: corruptURL).load() }
        let impossibleStore = FileReceiptStore(url: corruptURL.appendingPathComponent("receipts.json"))
        await expectError("NATIVE_ERROR") { try impossibleStore.save([]) }
        let stale = ActivitySnapshot(revision: 0, title: "x", status: "y", progress: 0, timer: nil, staleAt: -1)
        await expectError("INVALID_INPUT") { try stale.validate(template: "progress") }
        await expectError("INVALID_INPUT") { try EndPolicy(kind: "unknown", at: nil).validate() }
        try EndPolicy(kind: "after", at: Int64(Date().timeIntervalSince1970 * 1000) + 60_000).validate()
        let osTerminalBackend = FakeBackend()
        let osTerminalController = LiveActivityController(backend: osTerminalBackend)
        let terminalStart = try await osTerminalController.start(request("terminal"))
        let old = osTerminalBackend.activities[0]
        osTerminalBackend.activities = [NativeActivity(id: old.id, attributes: old.attributes, snapshot: old.snapshot, state: "ended")]
        let terminalEnd = try await LiveActivityController(backend: osTerminalBackend).end(EndRequest(id: terminalStart.id, policy: EndPolicy(kind: "default", at: nil)))
        expect(terminalEnd.state == "ended", "OS terminal activity end is idempotent after restart without receipts")
        try ActivitySnapshot(revision: 0, title: "\u{0085}", status: "ok", progress: 0, timer: nil, staleAt: nil).validate(template: "progress")
        expect(true, "U+0085 is nonblank under the shared JSON Schema contract")
        await expectError("INVALID_INPUT") { try ActivitySnapshot(revision: 0, title: "\u{feff}", status: "ok", progress: 0, timer: nil, staleAt: nil).validate(template: "progress") }
        testPlatformSupport()
        try await testPlatformCoverageGaps()
        try testLayoutFixtures()
        try await testLayoutModels()
        try testLayoutRender()
        try testLayoutCustomizations()
        try await testLayoutLifecycle()
        try await testReceipts()
        try await testBridge()
        print("Swift tests: \(assertions) assertions passed")
    }
}
