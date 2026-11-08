import Foundation

extension LifecycleTests {
    static let sessionLayout = """
    {"activityKey":"fremen:session","schemaVersion":2,"fallback":"notification","layout":{"lockScreen":{"type":"vstack","children":[
    {"type":"hstack","children":[{"type":"symbol","name":"timer","rendering":"hierarchical","style":"accent"},
    {"type":"text","bind":"title","style":"title"},{"type":"spacer"},{"type":"timerText","start":"from","end":"to","style":"digits"}],
    "spacing":8,"alignment":"center"},{"type":"progress","bind":"progress","kind":"linear","style":"bar"},
    {"type":"text","bind":"note","style":"note","if":"hasNote"},
    {"type":"button","actionId":"session.pause","child":{"type":"text","value":"Pause"},"style":"action","unless":"paused"}],
    "spacing":6,"alignment":"leading","style":"card"},"island":{"expanded":{"leading":{"type":"symbol","name":"timer","style":"accent"},
    "trailing":{"type":"timerText","start":"from","end":"to","style":"digits"},"center":{"type":"text","bind":"title","style":"title"},
    "bottom":{"type":"progress","bind":"progress","style":"bar"}},"compactLeading":{"type":"symbol","name":"timer","style":"accent"},
    "compactTrailing":{"type":"timerText","start":"from","end":"to","style":"digits"},"minimal":{"type":"symbol","name":"timer"}},
    "background":{"light":"#FFFFFF","dark":"#111111"},"keyline":"accent"},"styles":{"card":{"padding":[12,16,12,16]},
    "accent":{"color":"accent"},"title":{"font":"headline","lineLimit":1},"digits":{"size":15,"design":"monospaced","monospacedDigit":true},
    "bar":{"tint":"accent"},"note":{"font":"caption","color":"secondary","lineLimit":2},"action":{"buttonStyle":"bordered","tint":"accent"}},
    "snapshot":{"revision":0,"values":{"title":"집중 시간","progress":0.25,"from":1790000000000,"to":1790000600000,"note":"","hasNote":false,
    "paused":false},"staleAt":1790000900000},"android":{"visibility":"private"}}
    """

    /// A layout start body; every part can be replaced.
    static func layoutJSON(key: String = "layout:1", lockScreen: String = #"{"type":"text","bind":"title"}"#,
                           values: String = #"{"title":"Run"}"#, revision: Int64 = 0, layout: String = "", rest: String = "") -> String {
        #"{"activityKey":"\#(key)","schemaVersion":2,"fallback":"none","layout":{"lockScreen":\#(lockScreen)\#(layout)},"#
            + #""snapshot":{"revision":\#(revision),"values":\#(values)}\#(rest)}"#
    }
    /// `expect` for conditions that throw or await.
    @MainActor static func verify(_ condition: @autoclosure () async throws -> Bool, _ label: String) async rethrows {
        let value = try await condition()
        expect(value, label)
    }
    static func layoutRequest(_ json: String) throws -> LayoutRequest {
        try JSONDecoder().decode(LayoutRequest.self, from: Data(json.utf8))
    }
    static func canonical(_ data: Data) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys]), as: UTF8.self)
    }
    @MainActor static func expectUndecodable(_ json: String, _ label: String) {
        do {
            _ = try layoutRequest(json)
            expect(false, "strict decoding must reject \(label)")
        } catch { expect(error is DecodingError, "strict decoding rejects \(label)") }
    }

    @MainActor private static func testBoundMembers() async throws {
        let bound = ##"{"size":{"bind":"a"},"weight":{"bind":"b"},"color":{"bind":"c"},"background":{"bind":"d"},"cornerRadius":{"bind":"e"},"##
            + ##""opacity":{"bind":"f"},"tint":{"bind":"g"}}"##
        let json = layoutJSON(lockScreen: #"{"type":"text","value":"x","style":"s"}"#,
                              values: ##"{"a":12,"b":"bold","c":"red","d":"#FFFFFF","e":4,"f":0.5,"g":"mint","p":"clear","k":"orange"}"##,
                              layout: ##","background":{"bind":"p"},"keyline":{"bind":"k"}"##, rest: #","styles":{"s":\#(bound)}"#)
        let request = try layoutRequest(json)
        try request.validate()
        try await verify(try canonical(JSONEncoder().encode(request)) == canonical(Data(json.utf8)), "bound members keep their wire shape")
        let style = request.styles?["s"]
        expect(style?.size == .bound("a") && style?.weight == .bound("b") && style?.color == .bound("c") && style?.background == .bound("d")
            && style?.cornerRadius == .bound("e") && style?.opacity == .bound("f") && style?.tint == .bound("g")
            && request.layout.background == .bound("p") && request.layout.keyline == .bound("k"), "bound members decode as bindings")
        let literal = try layoutRequest(layoutJSON(rest: ##","styles":{"s":{"size":12,"weight":"bold","color":{"light":"#000000","dark":"#FFFFFF"}}}"##))
        expect(literal.styles?["s"]?.size == .literal(12) && literal.styles?["s"]?.weight == .literal(.bold)
            && literal.styles?["s"]?.color == .literal(.pair(light: "#000000", dark: "#FFFFFF")), "literal members stay literal")
        // {"bind":"a"} weighs 2 + (4 + 3 + 3 + 1), like any object with one member.
        expect(LayoutBindable<Double>.bound("a").wireWeight == 13 && LayoutBindable<Double>.literal(1).wireWeight == 8,
               "a binding weighs as the object it is on the wire")
        for (label, style) in [
            ("a binding with a number key", #"{"size":{"bind":5}}"#), ("a binding with another member", ##"{"color":{"bind":"c","light":"#000000"}}"##),
            ("a binding with a null key", #"{"weight":{"bind":null}}"#), ("an empty binding", #"{"opacity":{}}"#),
            ("a binding inside a color pair", ##"{"color":{"light":{"bind":"a"},"dark":"#000000"}}"##), ("a bound font", #"{"font":{"bind":"a"}}"#),
            ("a bound design", #"{"design":{"bind":"a"}}"#), ("a bound monospacedDigit", #"{"monospacedDigit":{"bind":"a"}}"#),
            ("a bound line limit", #"{"lineLimit":{"bind":"a"}}"#), ("a bound scale factor", #"{"minimumScaleFactor":{"bind":"a"}}"#),
            ("a bound alignment", #"{"alignment":{"bind":"a"}}"#), ("a bound padding", #"{"padding":{"bind":"a"}}"#),
            ("a bound frame width", #"{"frame":{"width":{"bind":"a"}}}"#), ("a bound button style", #"{"buttonStyle":{"bind":"a"}}"#)
        ] { expectUndecodable(layoutJSON(rest: #","styles":{"s":\#(style)}"#), label) }
        expectUndecodable(layoutJSON(lockScreen: #"{"type":"vstack","spacing":{"bind":"a"},"children":[{"type":"divider"}]}"#), "a bound stack spacing")
    }

    @MainActor static func testLayoutModels() async throws {
        let minimal = try layoutRequest(layoutJSON(lockScreen: #"{"type":"text","value":"Hello"}"#, values: "{}"))
        try minimal.validate()
        expect(minimal.weight == 52, "weight counts the layout, an absent style table as {} and the values")
        expect(minimal.schemaVersion == 2 && minimal.styles == nil && minimal.android == nil, "absent members stay absent")

        let session = try layoutRequest(sessionLayout)
        try session.validate()
        expect(session.weight == 1663, "session layout weight matches the shared fixture")
        let encoded = try JSONEncoder().encode(session)
        try await verify(try canonical(encoded) == canonical(Data(sessionLayout.utf8)), "encoding is the wire shape with absent members omitted")
        try await verify(try JSONDecoder().decode(LayoutRequest.self, from: encoded).weight == 1663, "encoded requests decode again")
        expect(session.snapshot.values["title"] == .string("집중 시간") && session.snapshot.staleAt == 1_790_000_900_000, "snapshot members decode")
        expect(session.android?.visibility == .private, "android options decode")

        for (label, json) in [
            ("an unknown start member", layoutJSON(rest: #","template":"progress""#)),
            ("an unknown snapshot member", layoutJSON(values: #"{"title":"Run"},"title":"Run""#)),
            ("an unknown layout member", layoutJSON(layout: #","contentTransition":"numericText""#)),
            ("an unknown island member", layoutJSON(layout: #","island":{"minimal":{"type":"divider"},"compact":true}"#)),
            ("an unknown expanded member", layoutJSON(layout: #","island":{"expanded":{"center":{"type":"divider"},"top":1}}"#)),
            ("an unknown node member", layoutJSON(lockScreen: #"{"type":"divider","url":"x"}"#)),
            ("a member of another node type", layoutJSON(lockScreen: #"{"type":"text","value":"a","children":[]}"#)),
            ("spacing on a zstack", layoutJSON(lockScreen: #"{"type":"zstack","children":[{"type":"divider"}],"spacing":1}"#)),
            ("an unknown node type", layoutJSON(lockScreen: #"{"type":"Text","value":"a"}"#)),
            ("both conditions", layoutJSON(lockScreen: #"{"type":"divider","if":"title","unless":"title"}"#)),
            ("a text with value and bind", layoutJSON(lockScreen: #"{"type":"text","value":"a","bind":"title"}"#)),
            ("a text without value and bind", layoutJSON(lockScreen: #"{"type":"text"}"#)),
            ("an unknown image source member", layoutJSON(lockScreen: #"{"type":"image","source":{"asset":"a","appGroup":"b"}}"#)),
            ("an unknown style member", layoutJSON(rest: #","styles":{"s":{"border":1}}"#)),
            ("an unknown frame member", layoutJSON(rest: #","styles":{"s":{"frame":{"idealWidth":1}}}"#)),
            ("an unknown frame length word", layoutJSON(rest: #","styles":{"s":{"frame":{"maxWidth":"Infinity"}}}"#)),
            ("an unknown color pair member", layoutJSON(rest: ##","styles":{"s":{"color":{"light":"#000000","dark":"#FFFFFF","tint":1}}}"##)),
            ("a color pair without dark", layoutJSON(rest: ##","styles":{"s":{"color":{"light":"#000000"}}}"##)),
            ("an unknown android member", layoutJSON(rest: #","android":{"visibility":"public","channel":"x"}"#)),
            ("an unknown android visibility", layoutJSON(rest: #","android":{"visibility":"hidden"}"#)),
            ("a null stale time", layoutJSON(values: #"{"title":"Run"},"staleAt":null"#)),
            ("a null style table", layoutJSON(rest: #","styles":null"#)),
            ("a null island", layoutJSON(layout: #","island":null"#)),
            ("a null alignment", layoutJSON(lockScreen: #"{"type":"vstack","children":[{"type":"divider"}],"alignment":null}"#)),
            ("a null value", layoutJSON(values: #"{"title":null}"#)),
            ("an array value", layoutJSON(values: #"{"title":[]}"#)),
            ("a numeric string revision", #"{"activityKey":"a","schemaVersion":2,"fallback":"none","layout":{"lockScreen":{"type":"divider"}},"snapshot":{"revision":"0","values":{}}}"#),
            ("a boolean spacing", layoutJSON(lockScreen: #"{"type":"vstack","children":[{"type":"divider"}],"spacing":true}"#)),
            ("a fractional line limit", layoutJSON(rest: #","styles":{"s":{"lineLimit":1.5}}"#)),
            ("a v1 start body", #"{"activityKey":"a","schemaVersion":1,"template":"progress","fallback":"none","snapshot":{"revision":0,"title":"a","status":"b","progress":0}}"#)
        ] { expectUndecodable(json, label) }

        try await testBoundMembers()

        let composed = LayoutValue.string("Caf\u{00e9}"), decomposed = LayoutValue.string("Cafe\u{0301}")
        expect("Caf\u{00e9}" == "Cafe\u{0301}" && composed != decomposed, "string values compare by their UTF-8 bytes")
        expect(LayoutValue.number(3) == .number(3.0) && LayoutValue.bool(true) != .number(1) && LayoutValue.string("1") != .number(1),
               "values of different JSON types differ")
        let first = LayoutSnapshot(revision: 1, values: ["title": composed]), second = LayoutSnapshot(revision: 1, values: ["title": decomposed])
        expect(first != second && Set([first, second, first]).count == 2, "snapshots with NFC and NFD text differ")
        expect(first == LayoutSnapshot(revision: 1, values: ["title": composed], staleAt: nil), "equal snapshots are equal")
        expect(LayoutSnapshot(revision: 1, values: [:], staleAt: 5) != LayoutSnapshot(revision: 1, values: [:]), "stale time is part of a snapshot")

        let reordered = #"{"snapshot":{"values":{"title":"Run"},"revision":0},"layout":{"lockScreen":{"bind":"title","type":"text"}},"fallback":"none","schemaVersion":2,"activityKey":"layout:1"}"#
        let fingerprint = try layoutRequest(layoutJSON()).fingerprint()
        try await verify(fingerprint.count == 64 && fingerprint == (try layoutRequest(reordered).fingerprint()), "fingerprint ignores member order")
        try await verify(fingerprint != (try layoutRequest(layoutJSON(values: #"{"title":"Walk"}"#)).fingerprint()), "fingerprint covers the values")
        try await verify(fingerprint != (try layoutRequest(layoutJSON(lockScreen: #"{"type":"text","bind":"title","style":"s"}"#,
            rest: #","styles":{"s":{"size":12}}"#)).fingerprint()), "fingerprint covers the layout and styles")

        let attributes = try LiveActivityLayoutAttributes(request: session, instanceID: "la-ios-layout-1")
        try await verify(attributes.activityKey == "fremen:session" && attributes.schemaVersion == 2 && attributes.fallback == "notification"
            && attributes.instanceID == "la-ios-layout-1" && attributes.initialFingerprint == (try session.fingerprint()), "attributes copy the request")
        let attributeData = try JSONEncoder().encode(attributes)
        let attributeJSON = try JSONSerialization.jsonObject(with: attributeData) as? [String: Any]
        let document = attributeJSON?["document"] as? [String: Any]
        let sessionJSON = try JSONSerialization.jsonObject(with: Data(sessionLayout.utf8)) as? [String: Any]
        expect(Set(attributeJSON?.keys.map { $0 } ?? []) == ["instanceID", "activityKey", "schemaVersion", "fallback", "initialFingerprint", "document"],
               "attributes hold the document, not the snapshot")
        expect(Set(document?.keys.map { $0 } ?? []) == ["layout", "styles"]
            && NSDictionary(dictionary: document?["layout"] as? [String: Any] ?? [:]).isEqual(to: sessionJSON?["layout"] as? [String: Any] ?? [:]),
               "document encodes the layout in its wire shape")
        let restored = try JSONDecoder().decode(LiveActivityLayoutAttributes.self, from: attributeData)
        expect(restored.document.weight == session.document.weight && restored.document.styles?.count == 7, "attributes decode again")
        try await verify(try JSONDecoder().decode(LayoutSnapshot.self, from: JSONEncoder().encode(session.snapshot)) == session.snapshot, "content state decodes again")
        let bare = try LiveActivityLayoutAttributes(request: minimal, instanceID: "x")
        try await verify(!(String(decoding: try JSONEncoder().encode(bare), as: UTF8.self).contains("styles")), "an absent style table is not encoded")

        try PayloadLimit.check(attributes: attributes, snapshot: session.snapshot)
        let quotes = String(repeating: "\\\"", count: 1000)
        let escaped = try layoutRequest(layoutJSON(lockScreen: #"{"type":"divider"}"#, values: #"{"a":"\#(quotes)","b":"\#(quotes)","c":"\#(quotes)"}"#))
        try escaped.validate()
        expect(escaped.weight <= 3584, "escaped text fits the weight budget")
        await expectError("PAYLOAD_TOO_LARGE") {
            try PayloadLimit.check(attributes: LiveActivityLayoutAttributes(request: escaped, instanceID: "x"), snapshot: escaped.snapshot)
        }

        let timer = try layoutRequest(layoutJSON(lockScreen: #"{"type":"vstack","children":[{"type":"text","bind":"title"},{"type":"timerText","start":"from","end":"to"}]}"#,
            values: #"{"title":"Run","from":10,"to":20}"#))
        try timer.validate()
        let current = timer.snapshot
        func next(_ values: [String: LayoutValue], _ revision: Int64 = 1) -> LayoutSnapshot { LayoutSnapshot(revision: revision, values: values) }
        try next(["title": .string(""), "from": .number(0), "to": .number(1)]).validate(replacing: current, in: timer.document)
        await expectError("INVALID_INPUT") { try next(["title": .string("Run"), "from": .number(-5.5), "to": .number(0)]).validate(replacing: current, in: timer.document) }
        await expectError("INVALID_INPUT") { try next(["title": .string("Run"), "from": .number(10)]).validate(replacing: current, in: timer.document) }
        await expectError("INVALID_INPUT") {
            try next(["title": .string("Run"), "from": .number(10), "to": .number(20), "extra": .bool(true)]).validate(replacing: current, in: timer.document)
        }
        await expectError("INVALID_INPUT") {
            try next(["title": .string("Run"), "from": .number(10), "end": .number(20)]).validate(replacing: current, in: timer.document)
        }
        await expectError("INVALID_INPUT") {
            try next(["title": .number(1), "from": .number(10), "to": .number(20)]).validate(replacing: current, in: timer.document)
        }
        await expectError("INVALID_INPUT") {
            try next(["title": .string("Run"), "from": .number(10), "to": .bool(true)]).validate(replacing: current, in: timer.document)
        }
        await expectError("INVALID_INPUT") {
            try next(["title": .string("Run"), "from": .number(20), "to": .number(20)]).validate(replacing: current, in: timer.document)
        }
        let heavyLayout = try layoutRequest(layoutJSON(lockScreen: #"{"type":"text","value":"\#(String(repeating: "x", count: 200))"}"#,
            values: #"{"a":"","b":"","c":"","d":""}"#))
        let heavyValues: [String: LayoutValue] = ["a": .string(String(repeating: "x", count: 1000)), "b": .string(String(repeating: "x", count: 1000)),
            "c": .string(String(repeating: "x", count: 1000)), "d": .string(String(repeating: "x", count: 320))]
        try next(heavyValues).validate()
        await expectError("PAYLOAD_TOO_LARGE") { try next(heavyValues).validate(replacing: heavyLayout.snapshot, in: heavyLayout.document) }

        try LayoutUpdateRequest(id: "handle", snapshot: next(["count": .number(3), "done": .bool(false), "title": .string("Run")])).validate()
        expect(LayoutUpdateRequest(id: "handle", snapshot: next(["count": .number(3), "done": .bool(false), "title": .string("Run")])).weight == 46,
               "update weight is the weight of its values")
        for snapshot in [next([:], -1), next([:], 9_007_199_254_740_992), LayoutSnapshot(revision: 0, values: [:], staleAt: -1),
                         LayoutSnapshot(revision: 0, values: [:], staleAt: 8_640_000_000_000_001), next(["a": .number(.nan)]),
                         next(["a": .number(.infinity)]), next(["a": .number(8_640_000_000_000_001)]), next(["1a": .bool(true)]),
                         next(["a": .string(String(repeating: "x", count: 1001))])] {
            await expectError("INVALID_INPUT") { try snapshot.validate() }
        }
        try next(["a": .string(String(repeating: "\u{1F600}", count: 800))]).validate()
        await expectError("PAYLOAD_TOO_LARGE") { try next(["a": .string(String(repeating: "\u{1F600}", count: 1000))]).validate() }
        for id in ["", "  ", "\u{feff}", String(repeating: "a", count: 257)] {
            await expectError("INVALID_INPUT") { try LayoutUpdateRequest(id: id, snapshot: next([:])).validate() }
            await expectError("INVALID_INPUT") { try LayoutEndRequest(id: id, policy: EndPolicy(kind: "immediate", at: nil)).validate() }
        }
        try LayoutUpdateRequest(id: "\u{0085}", snapshot: next([:])).validate()
        try LayoutEndRequest(id: "handle", policy: EndPolicy(kind: "after", at: 0)).validate()
        for policy in [EndPolicy(kind: "after", at: nil), EndPolicy(kind: "immediate", at: 5), EndPolicy(kind: "default", at: 5),
                       EndPolicy(kind: "later", at: nil), EndPolicy(kind: "after", at: -1), EndPolicy(kind: "after", at: 8_640_000_000_000_001)] {
            await expectError("INVALID_INPUT") { try LayoutEndRequest(id: "handle", policy: policy).validate() }
        }
        let end = try JSONDecoder().decode(LayoutEndRequest.self, from: Data(#"{"id":"handle","policy":{"kind":"after","at":1793809500000}}"#.utf8))
        expect(end.id == "handle" && end.policy.kind == "after" && end.policy.at == 1_793_809_500_000, "end requests decode")
        let update = try JSONDecoder().decode(LayoutUpdateRequest.self, from: Data(#"{"id":"handle","snapshot":{"revision":4,"values":{"on":true}}}"#.utf8))
        expect(update.id == "handle" && update.snapshot == LayoutSnapshot(revision: 4, values: ["on": .bool(true)]), "update requests decode")
    }
}
