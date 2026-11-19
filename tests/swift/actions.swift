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

extension LiveActivityAction {
    /// The tap as the activity, the action and the state say it, without what the intent adds of the tap itself.
    var plain: LiveActivityAction { LiveActivityAction(activityId: activityId, actionId: actionId, activityKey: activityKey, isOn: isOn) }
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

    // AK-TOGGLE-1
    /// The tap of a toggle carries the state the person asked for, from the intent through the relay to the bridge's
    /// event; the tap of a button carries none.
    @MainActor static func testToggleTaps() async throws {
        let center = NotificationCenter()
        let relay = ActionRelay(center: center) { _ in "job:1" }
        let heard = TapLog()
        relay.register(heard.record)
        let asked = try await ActionPost.post(activityId: "la-1", actionId: "mute", isOn: true, center: center)
        let plain = try await ActionPost.post(activityId: "la-1", actionId: "stop", center: center)
        let undone = try await ActionPost.post(activityId: "la-1", actionId: "mute", isOn: false, center: center)
        expect(asked && plain && undone, "each tap is acknowledged")
        expect(heard.actions.map(\.plain) == [LiveActivityAction(activityId: "la-1", actionId: "mute", activityKey: "job:1", isOn: true),
                                 LiveActivityAction(activityId: "la-1", actionId: "stop", activityKey: "job:1"),
                                 LiveActivityAction(activityId: "la-1", actionId: "mute", activityKey: "job:1", isOn: false)],
               "the relay hands on the state a toggle was asked for, and none for a button")
        func event(_ action: LiveActivityAction) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(BridgeEvent.action(action))) as? NSDictionary ?? [:]
        }
        try await verify(try event(heard.actions[0].plain) == ["type": "action", "activityId": "la-1", "actionId": "mute", "activityKey": "job:1", "on": true],
                         "the bridge's event says which state was asked for")
        try await verify(try event(heard.actions[1].plain) == ["type": "action", "activityId": "la-1", "actionId": "stop", "activityKey": "job:1"],
                         "and nothing of a state for a button")

        // The intent carries the state as two values, since the system hands the app a value that was never set as
        // false: a tap is a toggle's only when it says so, and whatever its other value is, a button's has no state.
        expect(ActionPost.state(isToggle: false, isOn: false) == nil && ActionPost.state(isToggle: false, isOn: true) == nil,
               "a tap that does not say it is a toggle's asks for no state")
        expect(ActionPost.state(isToggle: true, isOn: true) == true && ActionPost.state(isToggle: true, isOn: false) == false,
               "a toggle's tap asks for the state it carries")
    }

    // AK-EVENT-3, AK-EVENT-4, AK-EVENT-6, AK-EVENT-14
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

        // The intent's side: it posts until the relay acknowledges the tap, for at most 5 s.
        expect(ActionPost.notification == ActionRelay.notification, "the intent posts what the relay observes")
        expect(ActionRelay.notification.rawValue == "io.github.1eedaegon.activitykit.action", "under the project's name, which no other library posts")
        expect(UInt64(ActionPost.attempts) * ActionPost.interval == 5_000_000_000, "the intent posts a tap for at most 5 s")
        let posting = NotificationCenter()
        let listening = ActionRelay(center: posting) { $0 == "la-2" ? "job:2" : nil }
        let heard = TapLog()
        listening.register(heard.record)
        let acknowledged = try await ActionPost.post(activityId: "la-2", actionId: "go", center: posting)
        expect(acknowledged && heard.actions.map(\.plain) == [LiveActivityAction(activityId: "la-2", actionId: "go", activityKey: "job:2")],
               "the intent's tap is delivered once and acknowledged")
        let unheard = NotificationCenter()
        let deaf = ActionRelay(center: unheard) { _ in nil }
        let began = Date()
        let given = try await ActionPost.post(activityId: "la-3", actionId: "lost", center: unheard, attempts: 3, interval: 10_000_000)
        expect(!given && Date().timeIntervalSince(began) >= 0.03, "without an acknowledgement the intent gives up after its attempts")
        withExtendedLifetime(deaf) {}

        // AK-EVENT-14: taps go through one queue. While a sink holds one, a later tap waits behind it, and an intent that
        // waits less than that gives up before its tap is taken; the tap still arrives afterwards.
        let line = NotificationCenter()
        let queued = ActionRelay(center: line) { _ in nil }
        // The first tap is held until the later intent has given up, not for a fixed time: a slow runner cannot let it go
        // early and turn the give-up into an acknowledgement.
        let handled = TapLog(), letGo = DispatchSemaphore(value: 0)
        queued.register { action in
            if action.actionId == "held" { handled.block(); letGo.wait() }
            handled.record(action)
        }
        let held = post(line, "held")
        await verify(await eventually { handled.blocked }, "the sink holds the first tap")
        let behind = try await ActionPost.post(activityId: "la-1", actionId: "behind", center: line, attempts: 5, interval: 20_000_000)
        expect(!behind, "an intent that waits 100 ms gives up while an earlier tap is held")
        letGo.signal()
        await verify(await eventually { handled.ids == ["held", "behind"] && held.isFinished },
                     "the later tap arrives once the held one is done")

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

    // AK-EVENT-12, AK-EVENT-16
    /// A tap that the app does not take while its intent posts it is kept on disk and handed on when a sink registers,
    /// in this launch or a later one: once, late, with its id, its time, the revision shown and the key it was drawn
    /// with. A tap that the app takes at once writes nothing.
    @MainActor static func testKeptTaps() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("activitykit-taps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        func files() -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted() }

        expect(ActionRelay.keptTaps == ActionTapKeeper.folder, "the intent keeps taps where the bridge looks for them")
        let sample = ActionTap(activityId: "la-1", actionId: "stop", at: Date(timeIntervalSince1970: 1_790_000_000))
        expect(ActionRelay.fileName(id: sample.id, at: sample.at) == ActionTapKeeper.fileName(of: sample), "under the same name")

        let running = NotificationCenter()
        let relay = ActionRelay(center: running, keptIn: folder) { _ in "job:1" }
        let heard = TapLog()
        relay.register(heard.record)
        let quick = ActionTap(activityId: "la-1", actionId: "stop", activityKey: "job:1", revision: 3)
        let taken = try await ActionPost.post(quick, center: running, keepingIn: folder, attempts: 5, interval: 10_000_000)
        expect(taken && files().isEmpty, "a tap that the app takes at once writes nothing")
        expect(heard.actions == [LiveActivityAction(activityId: "la-1", actionId: "stop", activityKey: "job:1", tapId: quick.id, tappedAt: quick.at, revision: 3)],
               "the tap carries its id, its time and the revision shown")

        var gone: ActionRelay? = ActionRelay(center: running, keptIn: folder) { _ in nil }
        let cold = NotificationCenter()
        gone = ActionRelay(center: cold, keptIn: folder) { _ in nil }
        let missed = ActionTap(activityId: "la-2", actionId: "stop", activityKey: "job:2", revision: 5)
        let given = try await ActionPost.post(missed, center: cold, keepingIn: folder, attempts: 4, interval: 10_000_000)
        expect(!given && files() == [ActionTapKeeper.fileName(of: missed)], "a tap that no sink took is kept")
        gone = nil
        withExtendedLifetime(gone) {}

        let next = NotificationCenter()
        let later = ActionRelay(center: next, keptIn: folder) { _ in nil }
        let afterwards = TapLog()
        later.register(afterwards.record)
        await verify(await eventually { afterwards.actions.count == 1 && files().isEmpty }, "the kept tap reaches the next sink, and its file goes")
        expect(afterwards.actions == [LiveActivityAction(activityId: "la-2", actionId: "stop", activityKey: "job:2", tapId: missed.id,
                                                         tappedAt: missed.at, revision: 5, late: true)],
               "late, with the key it was drawn with, which ActivityKit no longer gives")
        let again = try await ActionPost.post(missed, center: next, keepingIn: folder, attempts: 3, interval: 10_000_000)
        expect(again && afterwards.actions.count == 1, "the same tap posted after its kept copy was handed on is acknowledged, not handed on again")

        let slow = NotificationCenter()
        let starting = ActionRelay(center: slow, keptIn: folder) { _ in "job:3" }
        let both = ActionTap(activityId: "la-3", actionId: "go")
        async let posted = ActionPost.post(both, center: slow, keepingIn: folder, attempts: 100, interval: 10_000_000)
        await verify(await eventually { files().count == 1 }, "a tap that is not taken at once is kept while it is posted")
        let starter = TapLog()
        starting.register(starter.record)
        let answered = try await posted
        await verify(await eventually { files().isEmpty }, "and its file is removed once the sink has it")
        expect(answered && starter.actions.count == 1 && starter.actions.first?.late == false, "a tap that waits and is kept is handed on once, not late")

        for index in 0..<40 {
            try ActionTapKeeper.keep(ActionTap(activityId: "la-4", actionId: "t\(index)", at: Date(timeIntervalSince1970: 1_790_000_000 + Double(index))), in: folder)
        }
        expect(files().count == ActionTapKeeper.limit && files().first?.contains("1790000008000") == true, "at most 32 taps are kept, the oldest dropped")
        let stale = ActionRelay(center: NotificationCenter(), keptIn: folder) { _ in nil }
        let none = TapLog()
        stale.register(none.record)
        await verify(await eventually { files().isEmpty }, "a tap kept longer than 12 hours is removed")
        expect(none.actions.isEmpty, "and not handed on")

        try Data("not a tap".utf8).write(to: folder.appendingPathComponent("000000000000000-broken.json"))
        let fresh = ActionTap(activityId: "la-5", actionId: "fresh")
        try ActionTapKeeper.keep(fresh, in: folder)
        let reader = ActionRelay(center: NotificationCenter(), keptIn: folder) { _ in nil }
        let read = TapLog()
        reader.register(read.record)
        await verify(await eventually { read.actions.count == 1 && files().isEmpty }, "a file that is no tap is removed, and the others are handed on")
        expect(read.ids == ["fresh"], "only the tap")

        let blocked = folder.appendingPathComponent("taps-in-a-file")
        try Data().write(to: blocked)
        let open = NotificationCenter()
        let opening = ActionRelay(center: open, keptIn: blocked) { _ in nil }
        let opened = TapLog()
        async let unkept = ActionPost.post(ActionTap(activityId: "la-6", actionId: "unkept"), center: open, keepingIn: blocked, attempts: 50, interval: 10_000_000)
        try await Task.sleep(nanoseconds: 50_000_000)
        opening.register(opened.record)
        let reached = try await unkept
        expect(reached && opened.ids == ["unkept"], "a tap that cannot be kept still reaches a sink that comes in time")
    }
}
