import Foundation

@MainActor
final class RecordingReceiptStore: ActivityReceiptStore {
    var records: [NativeActivity] = []
    func load() throws -> [NativeActivity] { records }
    func save(_ activities: [NativeActivity]) throws { records = activities }
}

extension LifecycleTests {
    @MainActor static func testPlatformCoverageGaps() async throws {
        for key in ["activity\n", "activity\r\n", "\nactivity"] {
            await expectError("INVALID_INPUT") { try request(key).validate() }
        }
        let backend = FakeBackend()
        let controller = LiveActivityController(backend: backend)
        let composed = ActivitySnapshot(revision: 0, title: "Caf\u{00e9}", status: "Ready", progress: 0.5, timer: nil, staleAt: nil)
        let unicode = try await controller.start(request("unicode", composed))
        let decomposed = ActivitySnapshot(revision: 0, title: "Cafe\u{0301}", status: "Ready", progress: 0.5, timer: nil, staleAt: nil)
        await expectError("CONFLICT") {
            _ = try await controller.update(UpdateRequest(id: unicode.id, snapshot: decomposed))
        }
        let statusComposed = ActivitySnapshot(revision: 1, title: "Tea", status: "Caf\u{00e9}", progress: 0.5, timer: nil, staleAt: nil)
        _ = try await controller.update(UpdateRequest(id: unicode.id, snapshot: statusComposed))
        let statusDecomposed = ActivitySnapshot(revision: 1, title: "Tea", status: "Cafe\u{0301}", progress: 0.5, timer: nil, staleAt: nil)
        await expectError("CONFLICT") {
            _ = try await controller.update(UpdateRequest(id: unicode.id, snapshot: statusDecomposed))
        }

        let timerSnapshot = ActivitySnapshot(revision: 0, title: "Mochi nap", status: "Resting", progress: nil,
            timer: ActivityTimer(startedAt: 1_000, endsAt: 121_000), staleAt: 60_000)
        let timerRequest = StartRequest(activityKey: "nap", schemaVersion: 1, template: "timer", fallback: "none", snapshot: timerSnapshot)
        let timer = try await controller.start(timerRequest)
        expect(timer.snapshot.timer?.endsAt == 121_000, "timer snapshots keep epoch milliseconds")
        let oldTimer = backend.activities.first { $0.id == timer.id }!
        backend.activities = backend.activities.map { $0.id == timer.id ? NativeActivity(id: oldTimer.id,
            attributes: oldTimer.attributes, snapshot: oldTimer.snapshot, state: "stale") : $0 }
        let staleList = try await controller.list()
        expect(staleList.first { $0.id == timer.id }?.state == "stale", "OS stale state is preserved")
        let timerUpdate = ActivitySnapshot(revision: 1, title: "Mochi nap", status: "Almost awake", progress: nil,
            timer: ActivityTimer(startedAt: 1_000, endsAt: 122_000), staleAt: 61_000)
        let refreshed = try await controller.update(UpdateRequest(id: timer.id, snapshot: timerUpdate))
        expect(refreshed.snapshot.timer?.endsAt == 122_000, "stale timer remains updateable")
        _ = try await controller.end(EndRequest(id: timer.id, policy: EndPolicy(kind: "default", at: nil)))

        let retentionBackend = FakeBackend()
        let store = RecordingReceiptStore()
        let retention = LiveActivityController(backend: retentionBackend, store: store)
        var ids: [String] = []
        for index in 0..<130 {
            let activity = try await retention.start(request("retention:\(index)"))
            ids.append(activity.id)
            _ = try await retention.end(EndRequest(id: activity.id, policy: EndPolicy(kind: "immediate", at: nil)))
        }
        expect(store.records.count == 128, "completed receipt storage remains bounded")
        let restored = LiveActivityController(backend: retentionBackend, store: store)
        let retained = try await restored.end(EndRequest(id: ids.last!, policy: EndPolicy(kind: "immediate", at: nil)))
        expect(retained.state == "ended", "latest terminal receipt survives restart")
        await expectError("NOT_FOUND") {
            _ = try await restored.end(EndRequest(id: ids[0], policy: EndPolicy(kind: "immediate", at: nil)))
        }
        await expectError("INVALID_INPUT") {
            try EndPolicy(kind: "after", at: 14_400_001).validate(now: Date(timeIntervalSince1970: 0))
        }
        try EndPolicy(kind: "after", at: 14_400_000).validate(now: Date(timeIntervalSince1970: 0))
        expect(true, "after dismissal accepts exactly the documented four-hour limit")
    }
}
