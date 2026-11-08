import Foundation

@MainActor
final class FakeLayoutBackend: LayoutActivityBackend {
    var activities: [LayoutActivity] = []
    var starts = 0
    var updates = 0
    /// How each activity ended: `end <revision>` published that snapshot, `keep` published nothing.
    var ends: [String] = []
    var preflights: [String] = []
    var failUpdate = false
    var delayObservation = false
    var startError: ActivityFailure?
    var widgetError: ActivityFailure?
    func preflightStart() throws { preflights.append("start"); if let error = startError { throw error } }
    func preflightLayoutWidget() throws { preflights.append("widget"); if let error = widgetError { throw error } }
    func list() async -> [LayoutActivity] { activities }
    func start(_ attributes: LiveActivityLayoutAttributes, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        starts += 1
        let activity = LayoutActivity(id: attributes.instanceID, attributes: attributes, snapshot: snapshot, state: "active")
        activities.append(activity)
        return activity
    }
    func update(_ activity: LayoutActivity, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        updates += 1
        await Task.yield()
        if failUpdate { throw ActivityFailure("NATIVE_ERROR", "update failed") }
        let next = LayoutActivity(id: activity.id, attributes: activity.attributes, snapshot: snapshot, state: "active")
        if !delayObservation { activities = activities.map { $0.id == activity.id ? next : $0 } }
        return next
    }
    func end(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        ends.append("end \(activity.snapshot.revision)")
        activities = activities.filter { $0.id != activity.id }
        return LayoutActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended")
    }
    func endKeepingContent(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        ends.append("keep")
        activities = activities.filter { $0.id != activity.id }
        return LayoutActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended")
    }
}

extension LifecycleTests {
    static let meterLayout = #"{"type":"vstack","children":[{"type":"text","bind":"title"},{"type":"progress","bind":"progress"}]}"#
    static func meterRequest(_ key: String = "job:1", title: String = "Download", progress: Double = 0, revision: Int64 = 0) throws -> LayoutRequest {
        try layoutRequest(layoutJSON(key: key, lockScreen: meterLayout, values: #"{"title":"\#(title)","progress":\#(progress)}"#, revision: revision))
    }
    static func meter(_ revision: Int64, _ progress: Double = 0, title: String = "Download") -> LayoutSnapshot {
        LayoutSnapshot(revision: revision, values: ["title": .string(title), "progress": .number(progress)])
    }
    static func layoutUpdate(_ id: String, _ snapshot: LayoutSnapshot) -> LayoutUpdateRequest { LayoutUpdateRequest(id: id, snapshot: snapshot) }
    static func layoutEnd(_ id: String, _ kind: String = "immediate", at: Int64? = nil) -> LayoutEndRequest {
        LayoutEndRequest(id: id, policy: EndPolicy(kind: kind, at: at))
    }

    // AK-END-3, AK-END-4, AK-END-5, AK-START-5, AK-START-9, AK-UPDATE-3, AK-UPDATE-4, AK-UPDATE-10
    @MainActor static func testLayoutLifecycle() async throws {
        let backend = FakeLayoutBackend()
        let controller = LayoutActivityController(backend: backend)
        let first = try await controller.start(meterRequest())
        expect(first.activityKey == "job:1" && first.schemaVersion == 2 && first.state == "active" && first.snapshot == meter(0), "layout start returns the record")
        expect(first.id.hasPrefix("la-ios-layout-") && first.id.count == 50 && backend.activities[0].attributes.instanceID == first.id, "layout handles are opaque instance IDs")
        expect(backend.preflights == ["start", "widget"], "a new layout start runs both preflights")
        let recordJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any]
        expect(Set(recordJSON?.keys.map { $0 } ?? []) == ["id", "activityKey", "schemaVersion", "snapshot", "backend", "state", "visibility",
            "degradedFeatures", "promotionRequested", "promotionState"], "the layout record carries no template and no layout")
        expect(recordJSON?["backend"] as? String == "activityKit" && recordJSON?["visibility"] as? String == "unknown"
            && recordJSON?["promotionState"] as? String == "notApplicable" && recordJSON?["promotionRequested"] as? Bool == false
            && (recordJSON?["degradedFeatures"] as? [Any])?.isEmpty == true, "the layout record keeps the constant members")
        expect(NSDictionary(dictionary: recordJSON?["snapshot"] as? [String: Any] ?? [:]).isEqual(to: ["revision": 0, "values": ["title": "Download", "progress": 0]]),
               "the record snapshot is the wire snapshot")
        let duplicate = try await controller.start(meterRequest())
        expect(duplicate.id == first.id && backend.starts == 1 && backend.preflights.count == 2, "duplicate layout start is idempotent and skips the preflights")
        await expectError("CONFLICT") { _ = try await controller.start(meterRequest(progress: 0.3)) }
        await expectError("CONFLICT") {
            _ = try await controller.start(layoutRequest(layoutJSON(key: "job:1", lockScreen: #"{"type":"text","bind":"title"}"#, values: #"{"title":"Download"}"#)))
        }
        await expectError("INVALID_INPUT") { _ = try await controller.start(layoutRequest(layoutJSON(key: "job:2", lockScreen: #"{"type":"text","bind":"absent"}"#))) }
        expect(backend.starts == 1, "an invalid layout start never reaches the backend")

        let updated = try await controller.update(layoutUpdate(first.id, meter(2, 0.5)))
        expect(updated.snapshot == meter(2, 0.5) && updated.id == first.id, "layout update applies the snapshot")
        _ = try await controller.update(layoutUpdate(first.id, meter(2, 0.5)))
        expect(backend.updates == 1, "same revision with the same values does not call native")
        await expectError("STALE_REVISION") { _ = try await controller.update(layoutUpdate(first.id, meter(1))) }
        await expectError("CONFLICT") { _ = try await controller.update(layoutUpdate(first.id, meter(2, 0.6))) }
        await expectError("INVALID_INPUT") {
            _ = try await controller.update(layoutUpdate(first.id, LayoutSnapshot(revision: 3, values: ["title": .string("Download")])))
        }
        await expectError("INVALID_INPUT") {
            _ = try await controller.update(layoutUpdate(first.id, LayoutSnapshot(revision: 3, values: ["title": .string("a"), "progress": .number(0), "more": .bool(true)])))
        }
        await expectError("INVALID_INPUT") {
            _ = try await controller.update(layoutUpdate(first.id, LayoutSnapshot(revision: 3, values: ["title": .number(1), "progress": .number(0)])))
        }
        await expectError("INVALID_INPUT") { _ = try await controller.update(layoutUpdate(" ", meter(3))) }
        await expectError("NOT_FOUND") { _ = try await controller.update(layoutUpdate("unknown", meter(3))) }
        await expectError("PAYLOAD_TOO_LARGE") { _ = try await controller.update(layoutUpdate(first.id, meter(3, title: String(repeating: "\u{1F600}", count: 900)))) }
        try meter(3, title: String(repeating: "\u{1F600}", count: 880)).validate()
        await expectError("PAYLOAD_TOO_LARGE") { _ = try await controller.update(layoutUpdate(first.id, meter(3, title: String(repeating: "\u{1F600}", count: 880)))) }
        expect(backend.updates == 1, "rejected layout updates never reach the backend")
        backend.failUpdate = true
        await expectError("NATIVE_ERROR") { _ = try await controller.update(layoutUpdate(first.id, meter(3))) }
        backend.failUpdate = false
        let recovered = LayoutActivityController(backend: backend)
        let recoveredList = try await recovered.list()
        expect(recoveredList.count == 1 && recoveredList[0].snapshot.revision == 2, "layout restart reads OS state")
        try await verify(try await recovered.start(meterRequest()).id == first.id, "layout restart preserves the duplicate-start fingerprint")
        let a = Task { try await controller.update(layoutUpdate(first.id, meter(3, 0.7))) }
        while backend.updates < 3 { await Task.yield() }
        let b = Task { try await controller.update(layoutUpdate(first.id, meter(4, 0.8))) }
        _ = try await a.value
        _ = try await b.value
        try await verify(try await controller.list().first?.snapshot.revision == 4, "concurrent layout updates serialize across suspension")

        let composed = try await controller.start(meterRequest("unicode", title: "Caf\u{00e9}"))
        await expectError("CONFLICT") { _ = try await controller.update(layoutUpdate(composed.id, meter(0, title: "Cafe\u{0301}"))) }
        try await verify(try await controller.update(layoutUpdate(composed.id, meter(0, title: "Caf\u{00e9}"))).id == composed.id, "the same bytes at the same revision are idempotent")

        let timerLayout = #"{"type":"timerText","start":"from","end":"to"}"#
        let timer = try await controller.start(layoutRequest(layoutJSON(key: "timer", lockScreen: timerLayout, values: #"{"from":1000,"to":2000}"#)))
        await expectError("INVALID_INPUT") {
            _ = try await controller.update(layoutUpdate(timer.id, LayoutSnapshot(revision: 1, values: ["from": .number(2000), "to": .number(2000)])))
        }
        let moved = try await controller.update(layoutUpdate(timer.id, LayoutSnapshot(revision: 1, values: ["from": .number(2000), "to": .number(2500)], staleAt: 3000)))
        expect(moved.snapshot.staleAt == 3000 && moved.snapshot.values["to"] == .number(2500), "layout update re-checks timer order against the stored layout")
        backend.activities = backend.activities.map {
            $0.id == timer.id ? LayoutActivity(id: $0.id, attributes: $0.attributes, snapshot: $0.snapshot, state: "stale") : $0
        }
        try await verify(try await controller.list().first { $0.id == timer.id }?.state == "stale", "OS stale state is preserved for layout activities")
        try await verify(try await controller.update(layoutUpdate(timer.id, LayoutSnapshot(revision: 2, values: ["from": .number(1), "to": .number(2)]))).snapshot.revision == 2,
               "a stale layout activity remains updateable")

        await expectError("INVALID_INPUT") { _ = try await controller.end(layoutEnd(first.id, "after", at: -1)) }
        await expectError("INVALID_INPUT") { _ = try await controller.end(layoutEnd(first.id, "immediate", at: 5)) }
        let ended = try await controller.end(layoutEnd(first.id))
        expect(ended.state == "ended" && ended.snapshot.revision == 4, "layout end returns the last accepted snapshot")
        try await verify(try await controller.end(layoutEnd(first.id, "after", at: 0)).id == ended.id, "a known layout end is idempotent before its policy is judged")
        await expectError("NOT_FOUND") { _ = try await controller.end(layoutEnd("unknown")) }
        await expectError("NOT_FOUND") { _ = try await controller.update(layoutUpdate(first.id, meter(5))) }
        let next = try await controller.start(meterRequest())
        expect(next.id != first.id && backend.starts == 4, "a new layout generation never reuses a handle")
        _ = try await controller.end(layoutEnd(next.id, "after", at: Int64(Date().timeIntervalSince1970 * 1000) + 60_000))
        _ = try await controller.end(layoutEnd(timer.id, "default"))

        backend.startError = ActivityFailure("PERMISSION_DENIED", "disabled")
        await expectError("PERMISSION_DENIED") { _ = try await controller.start(meterRequest("denied")) }
        backend.startError = nil
        backend.widgetError = ActivityFailure("CONFIGURATION_REQUIRED", "Embed a widget extension built from the layout template.")
        await expectError("CONFIGURATION_REQUIRED") { _ = try await controller.start(meterRequest("unembedded")) }
        expect(backend.starts == 4, "a failed preflight starts nothing")
        backend.widgetError = nil
        let quotes = String(repeating: "\\\"", count: 1000)
        await expectError("PAYLOAD_TOO_LARGE") {
            _ = try await controller.start(layoutRequest(layoutJSON(key: "escaped", lockScreen: #"{"type":"divider"}"#,
                values: #"{"a":"\#(quotes)","b":"\#(quotes)","c":"\#(quotes)"}"#)))
        }
        expect(backend.starts == 4, "a start over the encoded 4 KB limit starts nothing")

        let terminalBackend = FakeLayoutBackend()
        let terminal = try await LayoutActivityController(backend: terminalBackend).start(meterRequest("terminal"))
        terminalBackend.activities = terminalBackend.activities.map { LayoutActivity(id: $0.id, attributes: $0.attributes, snapshot: $0.snapshot, state: "ended") }
        let afterRestart = LayoutActivityController(backend: terminalBackend)
        try await verify(try await afterRestart.end(layoutEnd(terminal.id, "default")).state == "ended", "OS terminal layout activity end is idempotent without receipts")
        try await verify(try await afterRestart.list().first?.state == "ended", "a terminal receipt wins over the OS state")

        try await testBoundStyleUpdates()
        try await testContractIsolation()
        try testLayoutWidgetPreflight()
        try await testActionRelay()
        try await testNativeSizeCheck()
    }

    // AK-UPDATE-5
    /// An update re-checks the values that bound style members name, against the stored styles.
    @MainActor private static func testBoundStyleUpdates() async throws {
        let backend = FakeLayoutBackend()
        let controller = LayoutActivityController(backend: backend)
        func bound(_ key: String, tone: String) throws -> LayoutRequest {
            try layoutRequest(layoutJSON(key: key, lockScreen: #"{"type":"text","bind":"title","style":"s"}"#, values: #"{"title":"On time","tone":"\#(tone)"}"#,
                                         rest: #","styles":{"s":{"color":{"bind":"tone"}}}"#))
        }
        let started = try await controller.start(bound("bound", tone: "green"))
        let late = LayoutSnapshot(revision: 1, values: ["title": .string("Running late"), "tone": .string("red")])
        try await verify(try await controller.update(layoutUpdate(started.id, late)).snapshot == late, "an update changes a bound color")
        await expectError("INVALID_INPUT") {
            _ = try await controller.update(layoutUpdate(started.id, LayoutSnapshot(revision: 2, values: ["title": .string("Late"), "tone": .string("crimson")])))
        }
        await expectError("INVALID_INPUT") {
            _ = try await controller.update(layoutUpdate(started.id, LayoutSnapshot(revision: 2, values: ["title": .string("Late"), "tone": .number(1)])))
        }
        expect(backend.updates == 1, "an update with a value that a bound member cannot take never reaches the backend")
        await expectError("INVALID_INPUT") { _ = try await controller.start(bound("unbound", tone: "Green")) }
        expect(backend.starts == 1, "a start with such a value never reaches the backend")
    }

    // AK-START-6
    /// The weight is an estimate in front of the encoded 4096-byte check. Escapes take more bytes than they weigh, so a
    /// request within the weight can still be too large for ActivityKit.
    @MainActor private static func testNativeSizeCheck() async throws {
        let backend = FakeLayoutBackend()
        let controller = LayoutActivityController(backend: backend)
        func start(_ key: String, _ text: String, count: Int) throws -> LayoutRequest {
            let values = (0..<count).map { #""v\#($0)":"\#(text)""# }.joined(separator: ",")
            return try layoutRequest(layoutJSON(key: key, lockScreen: #"{"type":"divider"}"#, values: "{\(values)}"))
        }
        let controls = try start("controls", String(repeating: #"\u0001"#, count: 700), count: 1)
        let slashes = try start("slashes", String(repeating: "/", count: 1000), count: 3)
        let letters = try start("letters", String(repeating: "a", count: 1000), count: 3)
        for (request, label) in [(controls, "700 U+0001 characters"), (slashes, "3000 slashes")] {
            try request.validate()
            expect(request.weight <= LayoutRules.maxWeight, "\(label) are within the weight")
            await expectError("PAYLOAD_TOO_LARGE") { _ = try await controller.start(request) }
        }
        try letters.validate()
        _ = try await controller.start(letters)
        expect(controls.weight == 747 && slashes.weight == 3063 && letters.weight == 3063 && backend.starts == 1,
               "the same weight without escapes fits the encoded limit")
    }

    // AK-CONTRACT-5
    /// v1 and v2 share one receipt file and never see each other's activities.
    @MainActor private static func testContractIsolation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("receipts-v2.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileReceiptStore(url: url)
        let templateBackend = FakeBackend(), layoutBackend = FakeLayoutBackend()
        let template = LiveActivityController(backend: templateBackend, store: store)
        let layout = LayoutActivityController(backend: layoutBackend, store: store)
        let v1 = try await template.start(request("shared:key"))
        let v2 = try await layout.start(meterRequest("shared:key"))
        expect(v1.id != v2.id && v1.schemaVersion == 1 && v2.schemaVersion == 2, "one activity key lives once per contract version")
        await expectError("NOT_FOUND") { _ = try await template.update(UpdateRequest(id: v2.id, snapshot: snapshot(1))) }
        await expectError("NOT_FOUND") { _ = try await template.end(EndRequest(id: v2.id, policy: EndPolicy(kind: "immediate", at: nil))) }
        await expectError("NOT_FOUND") { _ = try await layout.update(layoutUpdate(v1.id, meter(1))) }
        await expectError("NOT_FOUND") { _ = try await layout.end(layoutEnd(v1.id)) }
        _ = try await template.update(UpdateRequest(id: v1.id, snapshot: snapshot(1, 0.5)))
        _ = try await layout.update(layoutUpdate(v2.id, meter(1, 0.5)))
        _ = try await layout.end(layoutEnd(v2.id))
        let stored = try FileReceiptStore(url: url).load()
        expect(stored.count == 2 && Set(stored.map(\.summary.schemaVersion)) == [1, 2], "the receipt file holds both contract versions")
        let restartedTemplate = LiveActivityController(backend: templateBackend, store: FileReceiptStore(url: url))
        let restartedLayout = LayoutActivityController(backend: layoutBackend, store: FileReceiptStore(url: url))
        try await verify(try await restartedTemplate.list().map(\.id) == [v1.id], "v1 lists only v1 activities")
        try await verify(try await restartedLayout.list().isEmpty, "v2 lists only v2 activities")
        try await verify(try await restartedLayout.end(layoutEnd(v2.id)).state == "ended", "the v2 tombstone survives v1 saves")
        await expectError("NOT_FOUND") { _ = try await restartedTemplate.end(EndRequest(id: v2.id, policy: EndPolicy(kind: "immediate", at: nil))) }
        try await verify(NativeActivity(id: "x", attributes: try LiveActivityAttributes(request: request(), instanceID: "x"), snapshot: snapshot(), state: "active").record.template == "progress",
               "a v1 activity still projects to its record")
    }

    // AK-START-9, AK-WIDGET-2
    @MainActor private static func testLayoutWidgetPreflight() throws {
        let plugIns = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("PlugIns")
        defer { try? FileManager.default.removeItem(at: plugIns.deletingLastPathComponent()) }
        func expectMissing(_ label: String, _ url: URL?) {
            do { try LayoutWidgetPreflight.check(plugIns: url); expect(false, label) }
            catch let failure as ActivityFailure {
                expect(failure.code == "CONFIGURATION_REQUIRED" && failure.message == "Embed a widget extension built from the layout template.", label)
            } catch { expect(false, label) }
        }
        func embed(_ name: String, _ info: [String: Any]?) throws {
            let bundle = plugIns.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            if let info = info {
                try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
            }
        }
        expectMissing("an app without a PlugIns folder has no layout widget", nil)
        expectMissing("a missing PlugIns folder has no layout widget", plugIns)
        try embed("Old.appex", ["NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"]])
        try embed("Empty.appex", nil)
        try embed("Text.appex", ["ActivityKitLayout": "2"])
        try embed("Newer.appex", ["ActivityKitLayout": 3])
        try embed("Resources.bundle", ["ActivityKitLayout": 2])
        expectMissing("extensions without the layout marker do not count", plugIns)
        try embed("Layout.appex", ["ActivityKitLayout": 2])
        try LayoutWidgetPreflight.check(plugIns: plugIns)
        expect(LayoutWidgetPreflight.infoKey == "ActivityKitLayout" && LayoutWidgetPreflight.version == 2, "an embedded layout widget passes the preflight")
    }
}
