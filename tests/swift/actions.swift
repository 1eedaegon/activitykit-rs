import Foundation

/// What a sink saw, written on the relay's queue and read by the test.
final class TapLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(action: LiveActivityAction, onMainThread: Bool)] = []
    private var running = false
    private func locked<Value>(_ body: () -> Value) -> Value { lock.lock(); defer { lock.unlock() }; return body() }
    func record(_ action: LiveActivityAction) { locked { entries.append((action, Thread.isMainThread)) } }
    func block() { locked { running = true } }
    var blocked: Bool { locked { running } }
    var actions: [LiveActivityAction] { locked { entries.map(\.action) } }
    var ids: [String] { actions.map(\.actionId) }
    var onMainThread: Bool { locked { entries.contains { $0.onMainThread } } }
}

extension LifecycleTests {
    /// Posts a tap as the intent template does; a repeated post passes the same acknowledgement.
    @discardableResult
    static func post(_ center: NotificationCenter, _ actionId: String, _ acknowledgement: Progress = .discreteProgress(totalUnitCount: 1),
                     activityId: String = "la-1") -> Progress {
        center.post(name: ActionRelay.notification, object: nil, userInfo: ["activityId": activityId, "actionId": actionId, "acknowledgement": acknowledgement])
        return acknowledgement
    }

    /// Waits up to 5 s for the relay's queue to make `condition` true.
    @MainActor static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    @MainActor static func testActionRelay() async throws {
        let center = NotificationCenter()
        let relay = ActionRelay(center: center) { $0 == "la-1" ? "job:1" : nil }
        let early = post(center, "early")
        post(center, "early", early)
        center.post(name: ActionRelay.notification, object: nil, userInfo: ["activityId": "la-1", "actionId": "unacknowledged"])
        center.post(name: ActionRelay.notification, object: nil, userInfo: ["activityId": 1, "actionId": "typed", "acknowledgement": Progress()])
        try await Task.sleep(nanoseconds: 50_000_000)
        expect(!early.isFinished, "a tap is not acknowledged before a sink takes it")

        let log = TapLog(), release = DispatchSemaphore(value: 0)
        relay.register { action in
            if action.actionId == "slow" { log.block(); release.wait() }
            log.record(action)
        }
        await verify(await eventually { early.isFinished }, "a waiting tap is acknowledged once the sink has it")
        expect(log.actions == [LiveActivityAction(activityId: "la-1", actionId: "early", activityKey: "job:1")],
               "a tap posted twice before the sink is delivered once, with its activity key")

        let slow = post(center, "slow")
        await verify(await eventually { log.blocked }, "the sink runs the tap")
        post(center, "slow", slow)
        post(center, "slow", slow)
        try await Task.sleep(nanoseconds: 50_000_000)
        expect(!slow.isFinished, "a tap is acknowledged only when the sink returns")
        release.signal()
        await verify(await eventually { slow.isFinished }, "the acknowledgement follows the sink")
        post(center, "slow", slow)
        post(center, "other", activityId: "la-gone")
        await verify(await eventually { log.ids.count == 3 }, "a later tap is delivered")
        expect(log.ids == ["early", "slow", "other"] && log.actions[2].activityKey == nil && !log.onMainThread,
               "repeated posts are delivered once, unknown activities have no key, and nothing runs on the main thread")

        let crowd = NotificationCenter()
        let crowded = ActionRelay(center: crowd) { _ in nil }
        let first = post(crowd, "tap0")
        for index in 1...ActionRelay.pendingLimit { post(crowd, "tap\(index)") }
        await verify(await eventually { first.isFinished }, "the oldest of 17 waiting taps is dropped and acknowledged")
        let later = TapLog()
        crowded.register(later.record)
        await verify(await eventually { later.ids.count == ActionRelay.pendingLimit }, "16 waiting taps reach the sink")
        expect(later.ids == (1...ActionRelay.pendingLimit).map { "tap\($0)" }, "waiting taps keep their order")

        let quiet = NotificationCenter()
        var gone: ActionRelay? = ActionRelay(center: quiet) { _ in nil }
        gone?.register { _ in }
        let probe = post(quiet, "probe")
        await verify(await eventually { probe.isFinished }, "a relay with a sink acknowledges taps")
        gone = nil
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = post(quiet, "after")
        try await Task.sleep(nanoseconds: 50_000_000)
        expect(gone == nil && !after.isFinished, "a released relay no longer takes taps")
    }
}
