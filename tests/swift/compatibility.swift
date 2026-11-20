import Foundation

extension LifecycleTests {
    /// A layout of every object the reader knows, each with a member of a later version (`later`), and the same layout
    /// without them.
    static func laterLayout(_ later: Bool) -> String {
        let extra = later ? #","later":{"any":[1,"two"]}"# : ""
        return #"""
        {"layout":{"lockScreen":{"type":"vstack","style":"card","children":[
        {"type":"text","value":"Title","accessibility":{"label":"Heading"\#(extra)}\#(extra)},
        {"type":"image","source":{"asset":"logo"\#(extra)}\#(extra)},
        {"type":"text","bind":"eta","style":"value"\#(extra)}]\#(extra)},
        "island":{"expanded":{"trailing":{"type":"text","bind":"eta"},"priority":{"trailing":2\#(extra)}\#(extra)},
        "margins":{"expanded":8\#(extra)}\#(extra)},
        "background":{"light":"#FFFFFF","dark":"#000000"\#(extra)},"url":{"bind":"link"\#(extra)}\#(extra)},
        "styles":{"card":{"padding":4,"frame":{"maxWidth":"infinity"\#(extra)}\#(extra)},"value":{"color":{"bind":"tint"\#(extra)}}}\#(extra)}
        """#
    }

    // AK-COMPAT-1, AK-COMPAT-2
    @MainActor static func testLaterVersions() throws {
        try testLaterLayouts()
        try testLaterNodeTypes()
        try testLaterContent()
    }

    /// A widget draws a layout of a later crate without the members it does not know; the app's requests stay strict.
    @MainActor private static func testLaterLayouts() throws {
        let values: [String: LayoutValue] = ["eta": .string("9 min"), "link": .string("demo://open"), "tint": .string("#00FF00")]
        let later = try JSONDecoder().decode(LayoutDocument.self, from: Data(laterLayout(true).utf8))
        let known = try JSONDecoder().decode(LayoutDocument.self, from: Data(laterLayout(false).utf8))
        for region in LayoutRegion.allCases {
            expect(later.render(region, values: values) == known.render(region, values: values),
                   "a layout with members of a later version draws as the same layout without them (\(region))")
        }
        let sorted = JSONEncoder(); sorted.outputFormatting = [.sortedKeys]
        let (laterData, knownData) = (try sorted.encode(later), try sorted.encode(known))
        expect(laterData == knownData, "what is not known is not kept")
        // What the reader knows it reads as before: a value it does not know of a member it knows is no layout.
        let unknownFont = #"{"layout":{"lockScreen":{"type":"text","value":"A"}},"styles":{"a":{"font":"enormous"}}}"#
        expect((try? JSONDecoder().decode(LayoutDocument.self, from: Data(unknownFont.utf8))) == nil, "an unknown font is refused")
        let nullMember = #"{"layout":{"lockScreen":{"type":"text","value":null}}}"#
        expect((try? JSONDecoder().decode(LayoutDocument.self, from: Data(nullMember.utf8))) == nil, "null is refused")
        // A request of the app is read strictly, at every level.
        let strict = try JSONDecoder.layoutRequests()
        let request = layoutJSON(lockScreen: #"{"type":"text","bind":"title","later":1}"#)
        expect((try? strict.decode(LayoutRequest.self, from: Data(request.utf8))) == nil, "a request with a member of a later version is refused")
        let update = #"{"id":"a","snapshot":{"revision":1,"values":{},"later":1}}"#
        expect((try? strict.decode(LayoutUpdateRequest.self, from: Data(update.utf8))) == nil, "an update with a later member is refused")
        let end = #"{"id":"a","policy":{"kind":"default","later":1}}"#
        expect((try? strict.decode(LayoutEndRequest.self, from: Data(end.utf8))) == nil, "an end with a later member is refused")
    }

    /// A node of a type the widget does not know draws as nothing, and a layout that is only such a node draws nothing.
    @MainActor private static func testLaterNodeTypes() throws {
        let values: [String: LayoutValue] = ["eta": .string("9 min")]
        let chart = #"{"type":"chart","series":"eta","style":"value","if":"eta"}"#
        let mixed = try layoutDocument(#"{"type":"hstack","children":[{"type":"text","value":"A"},\#(chart),{"type":"text","bind":"eta"}]}"#)
        expect(texts(mixed.render(.lockScreen, values: values)) == ["A", "9 min"], "an unknown node is left out of its stack")
        expect(children(mixed.render(.lockScreen, values: values)).map(\.slot) == [0, 2], "the others keep their places")
        let alone = try layoutDocument(chart)
        expect(alone.render(.lockScreen, values: values) == nil, "a region that is an unknown node draws nothing")
        let island = try layoutDocument(#"{"type":"text","value":"A"}"#, layout: #","island":{"compactTrailing":\#(chart)}"#)
        expect(island.render(.compactTrailing, values: values) == nil, "an island part that is an unknown node draws nothing")
        let encoded = String(decoding: try JSONEncoder().encode(alone), as: UTF8.self)
        expect(encoded.contains(#""type":"chart""#), "an unknown node keeps its type when the document is encoded again")
        let strict = try JSONDecoder.layoutRequests()
        expect((try? strict.decode(LayoutRequest.self, from: Data(layoutJSON(lockScreen: chart).utf8))) == nil,
               "a request with a node type it does not know is refused")
        // A node type that is known reads its members as before.
        let brokenText = #"{"type":"text"}"#
        expect((try? layoutDocument(brokenText)) == nil, "a known node without what it needs is refused")
        expect((try? alone.validate()) == nil, "a document with an unknown node is never valid as a request")
    }

    /// The content state of a later server or crate is read with the members it knows.
    @MainActor private static func testLaterContent() throws {
        let later = #"{"revision":3,"values":{"eta":"9 min"},"staleAt":1790000900000,"later":{"x":1}}"#
        let snapshot = try JSONDecoder().decode(LayoutSnapshot.self, from: Data(later.utf8))
        expect(snapshot == LayoutSnapshot(revision: 3, values: ["eta": .string("9 min")], staleAt: 1_790_000_900_000),
               "a content state with a member of a later version reads as the same content without it")
        expect((try? JSONDecoder.layoutRequests().decode(LayoutSnapshot.self, from: Data(later.utf8))) == nil,
               "in a request the same content is refused")
        let attributes = #"{"instanceID":"i","activityKey":"k","schemaVersion":2,"fallback":"none","initialFingerprint":"f","#
            + #""document":\#(laterLayout(true)),"later":true}"#
        let decoded = try JSONDecoder().decode(LiveActivityLayoutAttributes.self, from: Data(attributes.utf8))
        expect(decoded.activityKey == "k" && decoded.document.layout.island != nil, "the attributes of a later crate are read")
    }
}
