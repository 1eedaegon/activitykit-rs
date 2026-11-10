import Foundation

extension LifecycleTests {
    @MainActor static func testPushes() async throws {
        try await testPushRequests()
        try testPushEvents()
        try await testPushSettings()
        try await testPushedActivityKey()
        try testPayloadsDecodeAsTheWidgetReadsThem()
    }

    static let pushValues = #"{"title":"Rec","progress":0.2}"#

    // AK-PUSH-1, AK-PUSH-3
    /// The start request names what the activity asks for, and the backend gets it beside the content.
    @MainActor static func testPushRequests() async throws {
        let system = install()
        for (member, expected) in [(#""token""#, LayoutPush.token), (#"{"channel":"dHN0LXNyY2gtY2hubA=="}"#, .channel("dHN0LXNyY2gtY2hubA=="))] {
            let request = layoutJSON(key: "push:\(system.backend?.base.starts ?? 0)", lockScreen: meterLayout, values: pushValues, revision: 0)
            let started = await call(C.start, #"{"request":\#(request.dropLast()),"push":\#(member)}}"#)
            expect(started["ok"] as? Bool == true, "a start asking for \(member) succeeds")
            expect(system.backend?.pushes.last == .some(expected), "the backend gets \(member) with the start")
        }
        let plain = layoutJSON(key: "push:plain", lockScreen: meterLayout, values: pushValues, revision: 0)
        _ = await call(C.start, #"{"request":\#(plain)}"#)
        expect(system.backend?.pushes.last == .some(nil), "without the member the start asks for nothing")
        for bad in [#""later""#, #"{"channel":1}"#, #"{"channel":"x","more":1}"#, "1", "null"] {
            let request = layoutJSON(key: "push:bad", lockScreen: meterLayout, values: pushValues, revision: 0)
            let started = await call(C.start, #"{"request":\#(request.dropLast()),"push":\#(bad)}}"#)
            expect(code(started) == "INVALID_INPUT", "a push that is neither token nor channel is INVALID_INPUT: \(bad)")
        }
        let decoded = try layoutRequest(#"{"activityKey":"a","schemaVersion":2,"fallback":"none","layout":{"lockScreen":\#(meterLayout)},"snapshot":{"revision":0,"values":\#(pushValues)},"push":{"channel":"abc="}}"#)
        expect(decoded.push == .channel("abc="), "the request decodes a channel")
        let encoded = String(decoding: try JSONEncoder().encode(decoded.push), as: UTF8.self)
        expect(encoded == #"{"channel":"abc="}"#, "and encodes it as it came: \(encoded)")
        let token = String(decoding: try JSONEncoder().encode(LayoutPush.token), as: UTF8.self)
        expect(token == #""token""#, "a token encodes as its name")
        let without = try layoutRequest(#"{"activityKey":"a","schemaVersion":2,"fallback":"none","layout":{"lockScreen":\#(meterLayout)},"snapshot":{"revision":0,"values":\#(pushValues)}}"#)
        let same = try decoded.fingerprint() == without.fingerprint()
        expect(same, "what the start asks for is no part of the fingerprint")
    }

    // AK-PUSH-2, AK-PUSH-6
    /// The events of the Swift layer reach the handler as Rust reads them.
    @MainActor static func testPushEvents() throws {
        _ = install()
        C.register(logEvent)
        let before = EventLog.shared.events.count
        EventSink.shared.emit(.pushToken(activityId: "la-ios-layout-1", activityKey: "rec:1", token: "0a1bff"))
        EventSink.shared.emit(.pushToStartToken(token: "abcd"))
        let snapshot = LayoutSnapshot(revision: 7, values: ["title": .string("Pushed"), "progress": .number(0.9)], staleAt: 1_700_000_600_000, timestamp: 1_700_000_000_000)
        EventSink.shared.emit(.content(activityId: "la-ios-layout-1", activityKey: "rec:1", snapshot: snapshot, relevance: 80))
        EventSink.shared.emit(.content(activityId: "la-ios-layout-2", activityKey: "rec:2", snapshot: LayoutSnapshot(revision: 1, values: [:]), relevance: nil))
        let events = Array(EventLog.shared.events.dropFirst(before))
        expect(events.count == 4, "four events reached the handler")
        expect(events[0] as NSDictionary == ["type": "pushToken", "activityId": "la-ios-layout-1", "activityKey": "rec:1", "token": "0a1bff"],
               "a push token names its activity and the token in hex")
        expect(events[1] as NSDictionary == ["type": "pushToStartToken", "token": "abcd"], "a push-to-start token carries the token alone")
        let content = events[2]
        let shown = content["snapshot"] as? [String: Any]
        expect(content["type"] as? String == "content" && content["activityId"] as? String == "la-ios-layout-1"
               && content["activityKey"] as? String == "rec:1" && content["relevance"] as? Double == 80, "content names its activity and relevance")
        expect(shown?["revision"] as? Int == 7 && (shown?["values"] as? [String: Any])?["title"] as? String == "Pushed"
               && shown?["staleAt"] as? Int == 1_700_000_600_000 && shown?["timestamp"] as? Int == 1_700_000_000_000,
               "the snapshot carries the revision, the values, the stale date and the timestamp")
        expect(events[3]["relevance"] == nil, "no relevance, no member")
    }

    // AK-PUSH-4, AK-PUSH-8
    /// The push-to-start setting holds like the receipts and starts the watch; frequent pushes are in the reply.
    @MainActor static func testPushSettings() async throws {
        let system = install()
        let set = configure(#"{"receipts":"full","pushToStart":true}"#)
        expect(set["ok"] as? Bool == true && data(set) as NSDictionary == ["receipts": "full", "pushToStart": true], "the setting holds")
        expect(system.pushToStartWatched == 1, "the system watches the push-to-start token once asked")
        expect(data(configure(#"{"receipts":"full","pushToStart":true}"#)) as NSDictionary == ["receipts": "full", "pushToStart": true], "the same settings again are fine")
        expect(system.pushToStartWatched == 1, "and the watch is not started again")
        expect(code(configure(#"{"receipts":"full"}"#)) == "CONFLICT", "settings without it are other settings")
        for bad in [#"{"pushToStart":true}"#, #"{"receipts":"full","pushToStart":"yes"}"#, #"{"receipts":"full","pushToStart":1}"#] {
            expect(code(configure(bad)) == "INVALID_INPUT", "settings are read strictly: \(bad)")
        }
        let plain = install()
        expect(data(configure(#"{"receipts":"full","pushToStart":false}"#)) as NSDictionary == ["receipts": "full"], "off is the default and is not written back")
        expect(plain.pushToStartWatched == 0, "nothing is watched by default")
        expect(code(configure(#"{"receipts":"full","pushToStart":true}"#)) == "CONFLICT", "the first settings hold")

        let fresh = install()
        fresh.reply = AuthorizationReply(supported: true, enabled: true, buttons: true, frequentPushes: true)
        let reply = now(C.authorization)
        expect(data(reply)["frequentPushes"] as? Bool == true, "the authorization carries frequent pushes")
        fresh.reply = AuthorizationReply(supported: true, enabled: true, buttons: true)
        expect(data(now(C.authorization))["frequentPushes"] as? Bool == false, "false unless the system says so")
    }

    // AK-PUSH-5
    /// An activity a push started, with the attributes Rust's start payload carries, is listed with its key; a keyed
    /// start of the app under that key conflicts even for the same layout and values, since the server's
    /// fingerprint is not the app's.
    @MainActor static func testPushedActivityKey() async throws {
        let system = install()
        _ = await list()
        let start = try pushPayload("start")
        let attributes = try decodePayload(LiveActivityLayoutAttributes.self, start["attributes"])
        let content = try decodePayload(LayoutSnapshot.self, start["content-state"])
        let computed = try LiveActivityLayoutAttributes(request: pushedRequest(start), instanceID: attributes.instanceID).initialFingerprint
        expect(attributes.initialFingerprint != computed, "the server's fingerprint is not the one the app would compute")
        system.backend?.base.activities.append(LayoutActivity(id: attributes.instanceID, attributes: attributes, snapshot: content, state: "active"))
        let records = (await list())["data"] as? [[String: Any]] ?? []
        expect(records.contains { $0["id"] as? String == attributes.instanceID && $0["activityKey"] as? String == attributes.activityKey },
               "the list has the pushed activity under its key")
        let same = try JSONSerialization.data(withJSONObject: pushedRequestJSON(start))
        let started = await call(C.start, same)
        expect(code(started) == "CONFLICT", "the app's keyed start of the same content under the pushed key conflicts")
    }

    /// The `aps` of one payload of `tests/fixtures/push-payloads.json`, which Rust's tests write.
    static func pushPayload(_ name: String) throws -> [String: Any] {
        let fixtures = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("push-payloads.json")
        let payloads = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtures)) as? [String: [String: [String: Any]]] ?? [:]
        return payloads[name]?["aps"] ?? [:]
    }

    static func decodePayload<T: Decodable>(_ type: T.Type, _ object: Any?) throws -> T {
        try JSONDecoder().decode(type, from: try JSONSerialization.data(withJSONObject: object ?? NSNull()))
    }

    /// The start request the app would make for what a start payload started: the same key, layout, styles and values.
    static func pushedRequestJSON(_ start: [String: Any]) -> [String: Any] {
        let attributes = start["attributes"] as? [String: Any] ?? [:]
        let document = attributes["document"] as? [String: Any] ?? [:]
        var request: [String: Any] = ["activityKey": attributes["activityKey"] ?? "", "schemaVersion": 2, "fallback": attributes["fallback"] ?? "none",
                                      "layout": document["layout"] ?? [:], "snapshot": start["content-state"] ?? [:]]
        if let styles = document["styles"] { request["styles"] = styles }
        return ["request": request]
    }

    static func pushedRequest(_ start: [String: Any]) throws -> LayoutRequest {
        try decodePayload(LayoutRequest.self, pushedRequestJSON(start)["request"])
    }

    // AK-PUSH-9, AK-PUSH-10
    /// The payloads Rust builds decode into the attributes and the content state the widget reads.
    @MainActor static func testPayloadsDecodeAsTheWidgetReadsThem() throws {
        func aps(_ name: String) -> [String: Any] { (try? pushPayload(name)) ?? [:] }
        func decode<T: Decodable>(_ type: T.Type, _ object: Any?) throws -> T { try decodePayload(type, object) }
        let update = aps("update")
        let shown = try decode(LayoutSnapshot.self, update["content-state"])
        expect(update["event"] as? String == "update" && update["timestamp"] as? Int == 1_700_000_001, "an update names its event and the time of sending")
        expect(shown.revision == 3 && shown.values["tone"] == .string("red") && shown.values["level"] == .number(0.5)
               && shown.staleAt == 1_700_000_600_000 && shown.timestamp == 1_700_000_000_000, "its content state is a snapshot")
        expect((update["alert"] as? [String: Any])?["title"] as? String == "Louder" && update["stale-date"] as? Int == 1_700_000_600
               && update["relevance-score"] as? Double == 80, "with the alert, the stale date in seconds and the relevance")
        let end = aps("end")
        expect(end["event"] as? String == "end" && end["dismissal-date"] as? Int == 1_700_003_600 && end["content-state"] == nil,
               "an end without content names its dismissal")
        let start = aps("start")
        expect(start["attributes-type"] as? String == String(describing: LiveActivityLayoutAttributes.self), "the attributes type is the widget's")
        let attributes = try decode(LiveActivityLayoutAttributes.self, start["attributes"])
        expect(attributes.instanceID == "la-ios-layout-push-1" && attributes.activityKey == "pushed" && attributes.schemaVersion == 2
               && attributes.fallback == "none" && attributes.initialFingerprint.count == 64, "the attributes carry the handle, the key and the fingerprint")
        expect(String(describing: attributes.document.layout.lockScreen).contains("vstack"), "and the layout the widget draws: \(attributes.document.layout.lockScreen)")
        let first = try decode(LayoutSnapshot.self, start["content-state"])
        expect(first.revision == 0 && first.values["tone"] == .string("green"), "the first content is revision 0")
        expect(start["input-push-token"] as? Int == 1 && (start["alert"] as? [String: Any])?["body"] as? String == "Tap to look",
               "the start asks for a token and brings its alert")
    }
}
