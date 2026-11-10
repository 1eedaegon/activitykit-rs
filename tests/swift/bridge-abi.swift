import Foundation

/// A reply of the C bridge, set from whichever thread the bridge answers on.
final class ReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    private var calls = 0
    func set(_ data: Data) { lock.lock(); stored = data; calls += 1; lock.unlock() }
    var data: Data? { lock.lock(); defer { lock.unlock() }; return stored }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

/// The C callback the tests pass: `context` is a retained `ReplyBox`.
let replyToBox: AKReply = { context, bytes, count in
    guard let context else { return }
    let box = Unmanaged<ReplyBox>.fromOpaque(context).takeRetainedValue()
    box.set(bytes.map { Data(bytes: $0, count: count) } ?? Data())
}

/// What the C event handler got, in order.
final class EventLog: @unchecked Sendable {
    static let shared = EventLog()
    /// What a second handler got.
    static let other = EventLog()
    private let lock = NSLock()
    private var entries: [[String: Any]] = []
    func append(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.lock(); entries.append(object); lock.unlock()
    }
    var events: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return entries }
}

/// The bridge's C functions, found by their C symbols as the Rust library links them.
enum C {
    typealias Request = @convention(c) (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?, AKReply) -> Void
    typealias Now = @convention(c) (UnsafeMutableRawPointer?, AKReply) -> Void
    typealias Register = @convention(c) (AKEventHandler?) -> Void

    static func symbol<Function>(_ name: String, _ type: Function.Type) -> Function {
        // RTLD_DEFAULT: every image of the process, the test executable among them.
        guard let address = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { fatalError("The bridge exports no \(name)") }
        return unsafeBitCast(address, to: type)
    }

    static let start = symbol("ak_start", Request.self)
    static let update = symbol("ak_update", Request.self)
    static let end = symbol("ak_end", Request.self)
    static let list = symbol("ak_list", Now.self)
    static let authorization = symbol("ak_authorization", Now.self)
    static let imageFolder = symbol("ak_image_folder", Now.self)
    static let register = symbol("ak_set_event_handler", Register.self)
    static let configure = symbol("ak_configure", Request.self)
}

let logEvent: AKEventHandler = { bytes, count in
    guard let bytes else { return }
    EventLog.shared.append(Data(bytes: bytes, count: count))
}

let logOtherEvent: AKEventHandler = { bytes, count in
    guard let bytes else { return }
    EventLog.other.append(Data(bytes: bytes, count: count))
}

/// A layout backend that also records what the presentations held for each call.
@MainActor
final class PresentingBackend: LayoutActivityBackend {
    let base = FakeLayoutBackend()
    let presentations: Presentations
    var relevances: [Double?] = []
    var alerts: [AlertText?] = []
    /// The relevance each end saw, and its final snapshot.
    var ends: [(relevance: Double?, snapshot: LayoutSnapshot)] = []
    init(presentations: Presentations) { self.presentations = presentations }
    func preflightStart() throws { try base.preflightStart() }
    func preflightLayoutWidget() throws { try base.preflightLayoutWidget() }
    func list() async -> [LayoutActivity] { await base.list() }
    func start(_ attributes: LiveActivityLayoutAttributes, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        relevances.append(presentations.start(key: attributes.activityKey))
        return try await base.start(attributes, snapshot: snapshot)
    }
    func update(_ activity: LayoutActivity, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        let presentation = presentations.update(id: activity.id, revision: snapshot.revision)
        relevances.append(presentation?.relevance)
        alerts.append(presentation?.alert)
        return try await base.update(activity, snapshot: snapshot)
    }
    func end(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        ends.append((presentations.end(id: activity.id), activity.snapshot))
        return try await base.end(activity, policy: policy)
    }
}

/// The system of the host tests: supported, with a fake backend that each new controller gets fresh.
final class FakeSystem: BridgeSystem, @unchecked Sendable {
    var reply = AuthorizationReply(supported: true, enabled: true, buttons: true)
    /// Where the controller keeps its receipts, when a test wants a file, and the mode it was made with.
    var receipts: URL?
    @MainActor var mode: ReceiptMode?
    var folder: URL?
    var keys: [String: String] = [:]
    var observed: [EventSink] = []
    @MainActor var backend: PresentingBackend?
    func authorization() -> AuthorizationReply { reply }
    func imageFolder() throws -> URL {
        guard let folder else { throw ActivityFailure("CONFIGURATION_REQUIRED", "The widget extension names no App Group under ActivityKitAppGroup.") }
        return folder
    }
    func activityKey(of id: String) -> String? { keys[id] }
    @MainActor func makeController(presentations: Presentations, events: EventSink, receipts: ReceiptMode) throws -> LayoutActivityController {
        let created = PresentingBackend(presentations: presentations)
        backend = created
        mode = receipts
        return LayoutActivityController(backend: created, store: self.receipts.map { FileReceiptStore(url: $0, mode: receipts) })
    }
    func observe(_ events: EventSink) { observed.append(events) }
}

extension LifecycleTests {
    typealias Call = (UnsafePointer<UInt8>?, Int, UnsafeMutableRawPointer?, AKReply) -> Void

    static func object(_ data: Data?) -> [String: Any] {
        data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// Calls a C function of the bridge with `json` and waits for its reply.
    @MainActor static func call(_ function: Call, _ json: Data) async -> [String: Any] {
        let box = ReplyBox()
        let context = Unmanaged.passRetained(box).toOpaque()
        json.withUnsafeBytes { function($0.bindMemory(to: UInt8.self).baseAddress, $0.count, context, replyToBox) }
        for _ in 0..<5000 where box.data == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        expect(box.count == 1, "the bridge replies exactly once")
        return object(box.data)
    }

    @MainActor static func call(_ function: Call, _ json: String) async -> [String: Any] {
        await call(function, Data(json.utf8))
    }

    /// `ak_list`, which takes no request.
    @MainActor static func list() async -> [String: Any] {
        await call({ _, _, context, reply in C.list(context, reply) }, "")
    }

    /// A synchronous call, which must reply before it returns.
    static func now(_ function: (UnsafeMutableRawPointer?, AKReply) -> Void) -> [String: Any] {
        let box = ReplyBox()
        function(Unmanaged.passRetained(box).toOpaque(), replyToBox)
        return object(box.data)
    }

    static func code(_ reply: [String: Any]) -> String? {
        (reply["error"] as? [String: Any])?["code"] as? String
    }

    /// Every string value in a decoded JSON value, at any depth.
    static func strings(_ value: Any) -> [String] {
        if let text = value as? String { return [text] }
        if let list = value as? [Any] { return list.flatMap(strings) }
        if let object = value as? [String: Any] { return object.values.flatMap(strings) }
        return []
    }

    static func data(_ reply: [String: Any]) -> [String: Any] {
        reply["data"] as? [String: Any] ?? [:]
    }

    static func wrap(_ request: Any, _ extra: [String: Any] = [:]) throws -> Data {
        var envelope = extra
        envelope["request"] = request
        return try JSONSerialization.data(withJSONObject: envelope, options: [.fragmentsAllowed])
    }

    @MainActor static func install() -> FakeSystem {
        let system = FakeSystem()
        Systems.install(system)
        Bridge.shared.reset()
        Settings.shared.reset()
        return system
    }

    // AK-BRIDGE-8
    @MainActor static func testBridge() async throws {
        try await testBridgeLifecycle()
        try await testBridgeKeyedStart()
        try await testBridgeEndContent()
        try await testBridgeFromManyThreads()
        try testBridgeAuthorizationAndImages()
        try await testBridgeUnsupported()
        try await testBridgeEvents()
        try await testSettings()
        try await testBridgeFixtures()
        Systems.install(UnsupportedSystem())
        Bridge.shared.reset()
    }

    // AK-AUTH-2, AK-BRIDGE-1, AK-BRIDGE-2, AK-BRIDGE-3, AK-BRIDGE-7, AK-END-1, AK-END-4, AK-START-1, AK-START-4, AK-START-8, AK-UPDATE-1, AK-UPDATE-2, AK-UPDATE-6, AK-UPDATE-7, AK-CONTRACT-13
    @MainActor static func testBridgeLifecycle() async throws {
        let system = install()
        let request = layoutJSON(key: "rec:1", lockScreen: meterLayout, values: #"{"title":"Rec","progress":0.2}"#, revision: 0)
        let started = await call(C.start, #"{"request":\#(request),"relevance":50}"#)
        let record = data(started)
        let id = record["id"] as? String ?? ""
        expect(started["ok"] as? Bool == true && id.hasPrefix("la-ios-layout-") && record["activityKey"] as? String == "rec:1",
               "ak_start answers the record of the started activity")
        expect((record["snapshot"] as? [String: Any])?["revision"] as? Int == 0 && record["state"] as? String == "active"
               && record["backend"] == nil, "the record carries the snapshot and the state, and no backend")
        expect(system.backend?.relevances == [50], "the start's relevance reaches the backend while it starts")
        expect(Bridge.shared.presentations.start(key: "rec:1") == nil, "the presentation is forgotten after the call")

        let update = #"{"id":"\#(id)","snapshot":{"revision":1,"values":{"title":"Loud","progress":0.8}}}"#
        let updated = await call(C.update, #"{"request":\#(update),"relevance":80,"alert":{"title":"Loud","body":"High level"}}"#)
        expect((data(updated)["snapshot"] as? [String: Any])?["revision"] as? Int == 1, "ak_update applies the revision")
        expect(system.backend?.relevances.last == 80 && system.backend?.alerts == [AlertText(title: "Loud", body: "High level")],
               "the update's relevance and alert reach the backend")
        let plain = #"{"id":"\#(id)","snapshot":{"revision":2,"values":{"title":"Quiet","progress":0.1}}}"#
        _ = await call(C.update, #"{"request":\#(plain)}"#)
        expect(system.backend?.alerts.last == .some(nil), "an update without options has no alert")
        let stale = await call(C.update, #"{"request":\#(update)}"#)
        expect(code(stale) == "STALE_REVISION", "an older revision is STALE_REVISION")
        let other = await call(C.update, #"{"request":{"id":"unknown","snapshot":{"revision":3,"values":{"title":"a","progress":0}}}}"#)
        expect(code(other) == "NOT_FOUND", "an unknown handle is NOT_FOUND")
        let changed = await call(C.update, #"{"request":{"id":"\#(id)","snapshot":{"revision":3,"values":{"title":1,"progress":0}}}}"#)
        expect(code(changed) == "INVALID_INPUT", "a value that changes its type is INVALID_INPUT")

        let listed = await list()
        let records = listed["data"] as? [[String: Any]] ?? []
        expect(records.count == 1 && records[0]["id"] as? String == id, "ak_list answers every activity")
        let ended = await call(C.end, #"{"request":{"id":"\#(id)","policy":{"kind":"immediate"}}}"#)
        expect(data(ended)["state"] as? String == "ended", "ak_end ends the activity")
        let again = await call(C.end, #"{"request":{"id":"\#(id)","policy":{"kind":"immediate"}}}"#)
        expect(data(again)["state"] as? String == "ended", "a second end is fine")

        for broken in ["", "not json", "[]", #"{"request":null}"#, #"{"relevance":1}"#] {
            let (start, update, end) = (await call(C.start, broken), await call(C.update, broken), await call(C.end, broken))
            expect(code(start) == "INVALID_INPUT", "an unreadable start is INVALID_INPUT: \(broken)")
            expect(code(update) == "INVALID_INPUT", "an unreadable update is INVALID_INPUT: \(broken)")
            expect(code(end) == "INVALID_INPUT", "an unreadable end is INVALID_INPUT: \(broken)")
        }
        let values = #"{"title":"a","progress":0}"#
        let second = layoutJSON(key: "rec:2", lockScreen: meterLayout, values: values, revision: 0)
        let extra = await call(C.start, #"{"request":\#(second.dropLast()),"token":"x"}}"#)
        expect(code(extra) == "INVALID_INPUT", "a request with an unknown member is INVALID_INPUT")
        system.backend?.base.startError = ActivityFailure("PERMISSION_DENIED", "Live Activities are disabled in system settings.")
        let third = layoutJSON(key: "rec:3", lockScreen: meterLayout, values: values, revision: 0)
        let denied = await call(C.start, #"{"request":\#(third)}"#)
        expect(code(denied) == "PERMISSION_DENIED", "a backend failure keeps its code")
    }

    // AK-START-3
    /// A start with a key returns the running activity of that key for the same request, is CONFLICT for another one,
    /// and starts a new activity once the first has ended.
    @MainActor static func testBridgeKeyedStart() async throws {
        let system = install()
        let request = layoutJSON(key: "rec:keyed", lockScreen: meterLayout, values: #"{"title":"Rec","progress":0.2}"#, revision: 0)
        let first = data(await call(C.start, #"{"request":\#(request)}"#))["id"] as? String
        let again = data(await call(C.start, #"{"request":\#(request)}"#))["id"] as? String
        expect(first != nil && first == again && system.backend?.base.starts == 1, "the same keyed start returns the running activity")
        // Rust sends the time of each start in the snapshot: a later repeat differs only there, and is the same start.
        let stamped = { (at: Int) in
            layoutJSON(key: "rec:keyed", lockScreen: meterLayout, values: #"{"title":"Rec","progress":0.2}"#, revision: 0)
                .replacingOccurrences(of: #""revision":0,"#, with: #""revision":0,"timestamp":\#(at),"#)
        }
        let timed = data(await call(C.start, #"{"request":\#(stamped(1_790_000_000_000))}"#))["id"] as? String
        let later = data(await call(C.start, #"{"request":\#(stamped(1_790_000_000_001)),"relevance":80}"#))["id"] as? String
        expect(timed == first && later == first && system.backend?.base.starts == 1,
               "the same keyed start 1 ms later, with another relevance, returns the running activity")
        let other = layoutJSON(key: "rec:keyed", lockScreen: meterLayout, values: #"{"title":"Other","progress":0.2}"#, revision: 0)
        let conflict = await call(C.start, #"{"request":\#(other)}"#)
        expect(code(conflict) == "CONFLICT", "another start under a running key is CONFLICT")
        _ = await call(C.end, #"{"request":{"id":"\#(first ?? "")","policy":{"kind":"immediate"}}}"#)
        let fresh = data(await call(C.start, #"{"request":\#(other)}"#))["id"] as? String
        expect(fresh != nil && fresh != first, "after the end the key starts a new activity with a new handle")
    }

    // AK-END-5, AK-END-6, AK-UPDATE-11
    /// An end carries final content, checked like an update, and a relevance for that call only.
    @MainActor static func testBridgeEndContent() async throws {
        let system = install()
        let request = layoutJSON(key: "rec:end", lockScreen: meterLayout, values: #"{"title":"Rec","progress":0.2}"#, revision: 0)
        let id = data(await call(C.start, #"{"request":\#(request)}"#))["id"] as? String ?? ""
        let changed = await call(C.end, #"{"request":{"id":"\#(id)","policy":{"kind":"immediate"},"snapshot":{"revision":1,"values":{"title":1,"progress":1}}}}"#)
        expect(code(changed) == "INVALID_INPUT", "final values keep the keys and types of the start")
        let ended = await call(C.end, #"{"request":{"id":"\#(id)","policy":{"kind":"immediate"},"snapshot":{"revision":1,"values":{"title":"Done","progress":1},"timestamp":1790000000000}},"relevance":10}"#)
        let record = data(ended)
        let snapshot = record["snapshot"] as? [String: Any]
        expect(record["state"] as? String == "ended" && snapshot?["revision"] as? Int == 1
               && (snapshot?["values"] as? [String: Any])?["title"] as? String == "Done", "the end shows its final content")
        expect(system.backend?.ends.count == 1 && system.backend?.ends[0].relevance == 10
               && system.backend?.ends[0].snapshot.timestamp == 1_790_000_000_000, "the backend ends with that content and relevance")
        expect(Bridge.shared.presentations.end(id: id) == nil, "the end's relevance is forgotten after the call")
        let other = layoutJSON(key: "rec:end2", lockScreen: meterLayout, values: #"{"title":"Rec","progress":0.2}"#, revision: 0)
        let second = data(await call(C.start, #"{"request":\#(other)}"#))["id"] as? String ?? ""
        _ = await call(C.update, #"{"request":{"id":"\#(second)","snapshot":{"revision":3,"values":{"title":"a","progress":0}}}}"#)
        let stale = await call(C.end, #"{"request":{"id":"\#(second)","policy":{"kind":"default"},"snapshot":{"revision":2,"values":{"title":"b","progress":0}}}}"#)
        expect(code(stale) == "STALE_REVISION", "final content older than the shown one is STALE_REVISION")
        let plain = await call(C.end, #"{"request":{"id":"\#(second)","policy":{"kind":"default"}}}"#)
        expect((data(plain)["snapshot"] as? [String: Any])?["revision"] as? Int == 3, "without final content the last accepted one stays")
    }

    // AK-AUTH-1, AK-BRIDGE-3, AK-THREAD-1
    /// Rust may call from any thread, at the same time.
    @MainActor static func testBridgeFromManyThreads() async throws {
        _ = install()
        let boxes = (0..<8).map { _ in ReplyBox() }
        let values = #"{"title":"a","progress":0}"#
        let requests = (0..<8).map { index in
            let request = layoutJSON(key: "thread:\(index)", lockScreen: meterLayout, values: values, revision: 0)
            return Data(#"{"request":\#(request)}"#.utf8)
        }
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                let context = Unmanaged.passRetained(boxes[index]).toOpaque()
                requests[index].withUnsafeBytes { C.start($0.bindMemory(to: UInt8.self).baseAddress, $0.count, context, replyToBox) }
            }
        }
        await verify(await eventually { boxes.allSatisfy { $0.data != nil } }, "starts from 8 threads all get their reply")
        let ids = Set(boxes.compactMap { data(object($0.data))["id"] as? String })
        expect(ids.count == 8 && boxes.allSatisfy { $0.count == 1 }, "each of them started its own activity, replied once")
        let fromThread = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: now(C.authorization)) }
        }
        expect(data(fromThread)["enabled"] as? Bool == true, "ak_authorization answers on any thread before it returns")
    }

    // AK-AUTH-1, AK-AUTH-2, AK-BRIDGE-3, AK-IMAGE-4, AK-IMAGE-5
    @MainActor static func testBridgeAuthorizationAndImages() throws {
        let system = install()
        expect(data(now(C.authorization)) as NSDictionary == ["supported": true, "enabled": true, "buttons": true],
               "ak_authorization reports the system")
        system.reply = AuthorizationReply(supported: true, enabled: false, buttons: false)
        expect(data(now(C.authorization))["enabled"] as? Bool == false, "turned off in Settings")
        expect(code(now(C.imageFolder)) == "CONFIGURATION_REQUIRED", "no App Group, no image folder")
        system.folder = URL(fileURLWithPath: "/container/activitykit/images")
        expect(data(now(C.imageFolder))["path"] as? String == "/container/activitykit/images", "ak_image_folder names the folder")
    }

    // AK-BRIDGE-6, AK-START-7
    @MainActor static func testBridgeUnsupported() async throws {
        Systems.install(UnsupportedSystem())
        Bridge.shared.reset()
        let request = layoutJSON(key: "rec:1", lockScreen: meterLayout, values: #"{"title":"a","progress":0}"#, revision: 0)
        let (start, broken, listed) = (await call(C.start, #"{"request":\#(request)}"#), await call(C.start, "broken"), await list())
        expect(code(start) == "UNSUPPORTED_PLATFORM", "no Live Activities, no start")
        expect(code(broken) == "UNSUPPORTED_PLATFORM", "the platform is checked before the request")
        expect(code(listed) == "UNSUPPORTED_PLATFORM", "no list")
        expect(data(now(C.authorization)) as NSDictionary == ["supported": false, "enabled": false, "buttons": false],
               "an unsupported platform reports nothing enabled")
        expect(code(now(C.imageFolder)) == "UNSUPPORTED_PLATFORM", "no image folder")
        let system = UnsupportedSystem()
        system.observe(EventSink.shared)
        expect(system.activityKey(of: "x") == nil, "an unsupported platform knows no activity")
        do { _ = try system.makeController(presentations: Presentations(), events: .shared, receipts: .full); expect(false, "no controller") }
        catch let failure as ActivityFailure { expect(failure.code == "UNSUPPORTED_PLATFORM", "no controller without the platform") }
    }

    // AK-AUTH-3, AK-BRIDGE-5, AK-EVENT-1, AK-EVENT-2, AK-EVENT-4, AK-EVENT-8, AK-EVENT-12
    @MainActor static func testBridgeEvents() async throws {
        let system = install()
        system.keys["la-ios-layout-1"] = "rec:1"
        let early = post(.default, "early", activityId: "la-ios-layout-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        expect(!early.isFinished, "a tap waits until Rust registers its handler")
        C.register(logEvent)
        await verify(await eventually { early.isFinished && !EventLog.shared.events.isEmpty }, "the waiting tap reaches the handler")
        let first = EventLog.shared.events[0] as NSDictionary
        expect(first == ["type": "action", "activityId": "la-ios-layout-1", "actionId": "early", "activityKey": "rec:1"],
               "an action event carries the handle, the action and the key")
        let late = post(.default, "stop", activityId: "la-ios-layout-gone")
        await verify(await eventually { late.isFinished && EventLog.shared.events.count == 2 }, "a later tap arrives too")
        expect(EventLog.shared.events[1]["activityKey"] == nil, "an activity the system no longer lists has no key")
        expect(system.observed.count == 1, "the first handler starts the observation of states")
        system.observed[0].emit(.state(activityId: "la-ios-layout-1", activityKey: "rec:1", state: "dismissed"))
        system.observed[0].emit(.authorization(AuthorizationReply(supported: true, enabled: false, buttons: true)))
        expect(EventLog.shared.events.count == 4, "state and authorization events reach the handler at once")
        expect(EventLog.shared.events[2] as NSDictionary == ["type": "state", "activityId": "la-ios-layout-1", "activityKey": "rec:1", "state": "dismissed"]
               && EventLog.shared.events[3] as NSDictionary == ["type": "authorization",
                   "authorization": ["supported": true, "enabled": false, "buttons": true]], "they keep their wire shape")
        system.observed[0].emit(.started(activityId: "la-ios-layout-2", activityKey: "rec:2"))
        expect(EventLog.shared.events.count == 5 && EventLog.shared.events[4] as NSDictionary
               == ["type": "started", "activityId": "la-ios-layout-2", "activityKey": "rec:2"], "a new activity is a started event")
        C.register(logEvent)
        expect(system.observed.count == 1, "a second registration does not observe twice")
        // A different handler replaces the first: only it gets the next event.
        C.register(logOtherEvent)
        EventSink.shared.emit(.authorization(AuthorizationReply(supported: true, enabled: true, buttons: true)))
        expect(EventLog.other.events.count == 1 && EventLog.shared.events.count == 5, "a later handler replaces the earlier one")
        C.register(nil)
        EventSink.shared.emit(.authorization(AuthorizationReply(supported: true, enabled: true, buttons: true)))
        expect(EventLog.shared.events.count == 5, "without a handler events are dropped")
        C.register(logEvent)
    }

    // AK-CONTRACT-3, AK-CONTRACT-12, AK-END-3, AK-ERROR-2, AK-UPDATE-6
    /// Every case of the shared fixtures through the C functions, as Rust sends it: the bridge decodes it, the
    /// controller checks it, and the reply gives the fixture's verdict and code.
    @MainActor static func testBridgeFixtures() async throws {
        let file = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        guard let fixtures = try JSONSerialization.jsonObject(with: file) as? [String: [[String: Any]]] else { fatalError("Unreadable fixtures") }
        let functions: [String: Call] = ["start_layout": C.start, "update_layout": C.update, "end_layout": C.end]
        var checked = 0
        var messages = Set<String>()
        for fixture in fixtures["valid"] ?? [] where fixture["command"] as? String == "start_layout" {
            _ = install()
            let reply = await call(C.start, try wrap(fixture["input"] ?? NSNull()))
            expect(reply["ok"] as? Bool == true, "a valid start starts through the bridge: \(fixture["name"] ?? "")")
            checked += 1
        }
        // AK-END-3: the valid end policies, the past and the largest time among them, end a running activity.
        for fixture in fixtures["valid"] ?? [] where fixture["command"] as? String == "end_layout" {
            guard var end = fixture["input"] as? [String: Any], end["snapshot"] == nil else { continue }
            _ = install()
            let meter = layoutJSON(key: "end:policy", lockScreen: meterLayout, values: #"{"title":"Run","progress":0}"#)
            let started = await call(C.start, #"{"request":\#(meter)}"#)
            end["id"] = data(started)["id"]
            let reply = await call(C.end, try wrap(end))
            expect(reply["ok"] as? Bool == true && data(reply)["state"] as? String == "ended",
                   "a valid end policy ends through the bridge: \(fixture["name"] ?? "")")
            checked += 1
        }
        for fixture in fixtures["invalid"] ?? [] {
            guard let command = fixture["command"] as? String, let function = functions[command] else { continue }
            _ = install()
            let reply = await call(function, try wrap(fixture["input"] ?? NSNull()))
            expect(code(reply) == fixture["code"] as? String, "\(fixture["name"] ?? ""): expected \(fixture["code"] ?? ""), got \(code(reply) ?? "ok")")
            // AK-ERROR-2: the message is constant text, never a piece of the request.
            let message = ((reply["error"] as? [String: Any])?["message"] as? String) ?? ""
            for text in strings(fixture["input"] ?? NSNull()) where text.count >= 4 {
                expect(!message.contains(text), "\(fixture["name"] ?? ""): the message repeats \(text)")
            }
            messages.insert(message)
            checked += 1
        }
        expect(messages.count <= 12, "a few constant messages answer every invalid fixture: \(messages.sorted())")
        for fixture in fixtures["updates"] ?? [] {
            _ = install()
            let started = await call(C.start, try wrap(fixture["start"] ?? NSNull()))
            guard var update = fixture["update"] as? [String: Any], let id = data(started)["id"] as? String else { fatalError("Malformed update fixture") }
            update["id"] = id
            let reply = await call(C.update, try wrap(update))
            let expected = fixture["code"] as? String
            expect(code(reply) == expected && (expected != nil || reply["ok"] as? Bool == true),
                   "\(fixture["name"] ?? ""): expected \(expected ?? "ok"), got \(code(reply) ?? "ok")")
            checked += 1
        }
        for fixture in fixtures["ends"] ?? [] {
            _ = install()
            let started = await call(C.start, try wrap(fixture["start"] ?? NSNull()))
            guard var end = fixture["end"] as? [String: Any], let id = data(started)["id"] as? String else { fatalError("Malformed end fixture") }
            end["id"] = id
            let reply = await call(C.end, try wrap(end))
            let expected = fixture["code"] as? String
            expect(code(reply) == expected && (expected != nil || reply["ok"] as? Bool == true),
                   "\(fixture["name"] ?? ""): expected \(expected ?? "ok"), got \(code(reply) ?? "ok")")
            checked += 1
        }
        expect(checked >= 1000, "the fixtures went through the bridge")
        print("Bridge fixtures: \(checked) cases through the C functions match")
    }
}
