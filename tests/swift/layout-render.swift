import Foundation

extension LifecycleTests {
    static func layoutDocument(_ lockScreen: String, layout: String = "", styles: String? = nil) throws -> LayoutDocument {
        let json = #"{"layout":{"lockScreen":\#(lockScreen)\#(layout)}\#(styles.map { #","styles":\#($0)"# } ?? "")}"#
        return try JSONDecoder().decode(LayoutDocument.self, from: Data(json.utf8))
    }
    static func children(_ node: LayoutRenderNode?) -> [LayoutRenderNode] {
        switch node?.content {
        case let .vstack(children, _, _)?, let .hstack(children, _, _)?, let .zstack(children, _)?: return children
        default: return []
        }
    }
    static func texts(_ node: LayoutRenderNode?) -> [String] {
        children(node).compactMap { if case let .text(text) = $0.content { return text } else { return nil } }
    }

    @MainActor static func testLayoutRender() throws {
        try testRenderContent()
        try testRenderPaths()
        try testRenderStyles()
        try testRenderBoundStyles()
        try testIslandDefaults()
    }

    @MainActor private static func testRenderContent() throws {
        let conditions = try layoutDocument(#"{"type":"vstack","children":[{"type":"text","value":"a","if":"flag"},{"type":"text","value":"b","unless":"flag"},"#
            + #"{"type":"text","value":"c","if":"count"},{"type":"text","value":"d","unless":"note"}]}"#)
        expect(texts(conditions.render(.lockScreen, values: ["flag": .bool(true), "count": .number(0), "note": .string("")])) == ["a", "d"],
               "true shows if, zero and the empty string are not truthy")
        expect(texts(conditions.render(.lockScreen, values: ["flag": .bool(false), "count": .number(-1), "note": .string("x")])) == ["b", "c"],
               "false shows unless, other numbers and strings are truthy")
        expect(texts(conditions.render(.lockScreen, values: [:])) == ["b", "d"], "a missing value is not truthy")
        let hidden = try layoutDocument(#"{"type":"vstack","children":[{"type":"divider"}],"if":"on"}"#)
        expect(hidden.render(.lockScreen, values: ["on": .bool(false)]) == nil && hidden.render(.lockScreen, values: ["on": .bool(true)]) != nil,
               "a condition hides the node with its subtree")
        expect(LayoutValue.bool(true).isTruthy && !LayoutValue.bool(false).isTruthy && LayoutValue.number(0.5).isTruthy
            && !LayoutValue.number(0).isTruthy && LayoutValue.string(" ").isTruthy && !LayoutValue.string("").isTruthy, "truthiness of each value type")

        let bound = try layoutDocument(#"{"type":"text","bind":"v"}"#)
        let cases: [(LayoutValue, String)] = [
            (.string("집중 시간"), "집중 시간"), (.string(""), ""), (.bool(true), "true"), (.bool(false), "false"),
            (.number(3), "3"), (.number(0.25), "0.25"), (.number(-42.5), "-42.5"), (.number(1_790_000_000_000), "1790000000000"),
            (.number(-0.0), "0"), (.number(8_640_000_000_000_000), "8640000000000000"), (.number(-8_640_000_000_000_000), "-8640000000000000"),
            (.number(0.1 + 0.2), "0.30000000000000004"), (.number(0.00001), "0.00001"), (.number(0.000001234), "0.000001234"),
            (.number(1e-7), "1e-7"), (.number(-1.5e-7), "-1.5e-7"), (.number(1.5e17), "150000000000000000"),
            (.number(1e20), "100000000000000000000"), (.number(1e21), "1e+21"), (.number(1.25e22), "1.25e+22")
        ]
        for (value, text) in cases {
            expect(bound.render(.lockScreen, values: ["v": value])?.content == .text(text), "bound text of \(value) is \(text), got \(value.text)")
        }
        expect(bound.render(.lockScreen, values: [:]) == nil, "a bind without a value renders nothing")
        let literal = try layoutDocument(#"{"type":"text","value":"literal"}"#)
        expect(literal.render(.lockScreen, values: [:])?.content == .text("literal"), "literal text")
        expect(LayoutValue.number(2).number == 2 && LayoutValue.string("2").number == nil && LayoutValue.bool(true).number == nil, "only numbers are numbers")

        let progress = try layoutDocument(#"{"type":"hstack","children":[{"type":"progress","bind":"p"},{"type":"progress","bind":"p","kind":"circular"}]}"#)
        func meters(_ value: LayoutValue) -> [LayoutRenderContent] { children(progress.render(.lockScreen, values: ["p": value])).map(\.content) }
        expect(meters(.number(0.5)) == [.progress(value: 0.5, kind: .linear), .progress(value: 0.5, kind: .circular)], "progress kinds")
        expect(meters(.number(-1)).first == .progress(value: 0, kind: .linear) && meters(.number(2)).first == .progress(value: 1, kind: .linear),
               "progress is clamped to 0...1")
        expect(meters(.string("0.5")).isEmpty && meters(.bool(true)).isEmpty, "progress needs a number")

        let gauge = try layoutDocument(#"{"type":"hstack","children":[{"type":"gauge","bind":"g"},{"type":"gauge","bind":"g","min":10,"max":20,"kind":"circular"},"#
            + #"{"type":"gauge","bind":"g","max":50},{"type":"gauge","bind":"g","min":-5},{"type":"gauge","bind":"g","min":3}]}"#)
        func gauges(_ value: Double) -> [LayoutRenderContent] { children(gauge.render(.lockScreen, values: ["g": .number(value)])).map(\.content) }
        expect(gauges(15) == [.gauge(value: 1, range: 0...1, kind: .linear), .gauge(value: 15, range: 10...20, kind: .circular),
                              .gauge(value: 15, range: 0...50, kind: .linear), .gauge(value: 1, range: -5...1, kind: .linear)],
               "gauge range defaults to 0...1, values are clamped, an empty range renders nothing")
        expect(gauges(-9).map { content -> Double in if case let .gauge(value, _, _) = content { return value } else { return .nan } } == [0, 10, 0, -5],
               "gauge clamps to its lower bound")

        let timer = try layoutDocument(#"{"type":"hstack","children":[{"type":"timerText","start":"from","end":"to"},{"type":"timerText","start":"from","end":"to","countsDown":false}]}"#)
        let interval = Date(timeIntervalSince1970: 1)...Date(timeIntervalSince1970: 121.5)
        expect(children(timer.render(.lockScreen, values: ["from": .number(1_000), "to": .number(121_500)])).map(\.content)
            == [.timer(interval: interval, countsDown: true), .timer(interval: interval, countsDown: false)], "timer interval from epoch milliseconds")
        expect(children(timer.render(.lockScreen, values: ["from": .number(5), "to": .number(5)])).isEmpty
            && children(timer.render(.lockScreen, values: ["from": .number(5)])).isEmpty
            && children(timer.render(.lockScreen, values: ["from": .string("1"), "to": .number(5)])).isEmpty, "a timer needs an end after its start")

        let symbol = try layoutDocument(#"{"type":"hstack","children":[{"type":"symbol","name":"wifi"},{"type":"symbol","name":"wifi","rendering":"palette","variableBind":"level"}]}"#)
        func symbols(_ values: [String: LayoutValue]) -> [LayoutRenderContent] { children(symbol.render(.lockScreen, values: values)).map(\.content) }
        expect(symbols(["level": .number(0.3)]) == [.symbol(name: "wifi", rendering: nil, variableValue: nil),
                                                    .symbol(name: "wifi", rendering: .palette, variableValue: 0.3)], "symbol rendering and variable value")
        expect(symbols(["level": .number(1.5)]).last == .symbol(name: "wifi", rendering: .palette, variableValue: 1)
            && symbols(["level": .number(-1)]).last == .symbol(name: "wifi", rendering: .palette, variableValue: 0)
            && symbols([:]).last == .symbol(name: "wifi", rendering: .palette, variableValue: nil), "symbol variable value is clamped to 0...1")

        let image = try layoutDocument(#"{"type":"hstack","children":[{"type":"image","source":{"asset":"logo"}},{"type":"image","source":{"asset":"logo.dark"},"resizable":true,"contentMode":"fill"}]}"#)
        expect(children(image.render(.lockScreen, values: [:])).map(\.content) == [.image(source: .asset("logo"), resizable: false, contentMode: nil),
            .image(source: .asset("logo.dark"), resizable: true, contentMode: .fill)], "image asset, resizable and content mode")

        let stacks = try layoutDocument(#"{"type":"vstack","spacing":6,"alignment":"leading","children":[{"type":"hstack","alignment":"firstTextBaseline","children":[{"type":"spacer"},{"type":"spacer","minLength":4}]},"#
            + #"{"type":"zstack","alignment":"bottomTrailing","children":[{"type":"divider"}]},{"type":"hstack","children":[{"type":"text","value":"x","if":"off"}]},{"type":"zstack","children":[{"type":"divider"}]}]}"#)
        let root = stacks.render(.lockScreen, values: [:])
        guard case let .vstack(rows, spacing, alignment)? = root?.content else { fatalError("FAIL: vstack renders") }
        expect(spacing == 6 && alignment == .leading && rows.count == 4, "vstack spacing and alignment")
        expect(rows[0].content == .hstack(children: [LayoutRenderNode(content: .spacer(minLength: nil), style: .plain),
                                                    LayoutRenderNode(content: .spacer(minLength: 4), style: .plain)], spacing: nil, alignment: .firstTextBaseline),
               "hstack alignment and spacers")
        expect(rows[1].content == .zstack(children: [LayoutRenderNode(content: .divider, style: .plain)], alignment: .bottomTrailing), "zstack alignment and divider")
        expect(rows[2].content == .hstack(children: [], spacing: nil, alignment: .center) && rows[3].content == .zstack(children: [LayoutRenderNode(content: .divider, style: .plain)], alignment: .center),
               "hidden children are left out and alignments default to center")
        let plainStack = try layoutDocument(#"{"type":"vstack","children":[{"type":"divider"}]}"#).render(.lockScreen, values: [:])
        expect(plainStack?.content == .vstack(children: [LayoutRenderNode(content: .divider, style: .plain)], spacing: nil, alignment: .center), "vstack defaults")

        let button = try layoutDocument(#"{"type":"vstack","children":[{"type":"button","actionId":"session.pause","child":{"type":"text","bind":"label"},"style":"b"},"#
            + #"{"type":"button","actionId":"hidden","child":{"type":"text","value":"x","if":"off"}}]}"#, styles: #"{"b":{"buttonStyle":"bordered"}}"#)
        let buttons = children(button.render(.lockScreen, values: ["label": .string("Pause")]))
        expect(buttons.count == 1 && buttons[0].content == .button(actionId: "session.pause", label: LayoutRenderNode(content: .text("Pause"), style: .plain))
            && buttons[0].style.buttonStyle == .bordered, "a button carries its action and label; one without a label renders nothing")
    }

    @MainActor private static func testRenderPaths() throws {
        func curve(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ x: Double, _ y: Double) -> LayoutPathCommand {
            .curve(control1X: a, control1Y: b, control2X: c, control2Y: d, x: x, y: y)
        }
        let cases: [(String, [LayoutPathCommand])] = [
            ("M1 2L3 4H5V6Z", [.move(x: 1, y: 2), .line(x: 3, y: 4), .line(x: 5, y: 4), .line(x: 5, y: 6), .close]),
            ("m1 2l3 4h5v6z", [.move(x: 1, y: 2), .line(x: 4, y: 6), .line(x: 9, y: 6), .line(x: 9, y: 12), .close]),
            ("M0 0 10 10 20 0", [.move(x: 0, y: 0), .line(x: 10, y: 10), .line(x: 20, y: 0)]),
            ("m1 1 2 2", [.move(x: 1, y: 1), .line(x: 3, y: 3)]),
            ("M0 0H1 2 3V4 5", [.move(x: 0, y: 0), .line(x: 1, y: 0), .line(x: 2, y: 0), .line(x: 3, y: 0), .line(x: 3, y: 4), .line(x: 3, y: 5)]),
            ("M0 0C1 2 3 4 5 6 7 8 9 10 11 12", [.move(x: 0, y: 0), curve(1, 2, 3, 4, 5, 6), curve(7, 8, 9, 10, 11, 12)]),
            ("m10 10c1 2 3 4 5 6", [.move(x: 10, y: 10), curve(11, 12, 13, 14, 15, 16)]),
            ("M0 0C0 10 10 10 10 0S20-10 20 0", [.move(x: 0, y: 0), curve(0, 10, 10, 10, 10, 0), curve(10, -10, 20, -10, 20, 0)]),
            ("M1 1S2 2 3 3", [.move(x: 1, y: 1), curve(1, 1, 2, 2, 3, 3)]),
            ("M1 1s1 1 2 2", [.move(x: 1, y: 1), curve(1, 1, 2, 2, 3, 3)]),
            ("M0 0Q3 6 6 0", [.move(x: 0, y: 0), curve(2, 4, 4, 4, 6, 0)]),
            ("M0 0Q3 6 6 0T12 0", [.move(x: 0, y: 0), curve(2, 4, 4, 4, 6, 0), curve(8, -4, 10, -4, 12, 0)]),
            ("M0 0q3 6 6 0t6 0", [.move(x: 0, y: 0), curve(2, 4, 4, 4, 6, 0), curve(8, -4, 10, -4, 12, 0)]),
            ("M3 3T9 3", [.move(x: 3, y: 3), curve(3, 3, 5, 3, 9, 3)]),
            ("M0 0C1 1 2 2 3 3T9 3", [.move(x: 0, y: 0), curve(1, 1, 2, 2, 3, 3), curve(3, 3, 5, 3, 9, 3)]),
            ("M1 1L2 2ZL3 3zZ", [.move(x: 1, y: 1), .line(x: 2, y: 2), .close, .move(x: 1, y: 1), .line(x: 3, y: 3), .close, .close]),
            ("M1 1l1 1zl1 0", [.move(x: 1, y: 1), .line(x: 2, y: 2), .close, .move(x: 1, y: 1), .line(x: 2, y: 1)]),
            ("M0 0zm1 1", [.move(x: 0, y: 0), .close, .move(x: 1, y: 1)]),
            ("M.5-.5", [.move(x: 0.5, y: -0.5)]), ("M1.5.5", [.move(x: 1.5, y: 0.5)]), ("M1e5.5", [.move(x: 100_000, y: 0.5)]),
            ("M+1-2", [.move(x: 1, y: -2)]), ("M1e2 3E-1", [.move(x: 100, y: 0.3)]), ("M1e+2,3E0", [.move(x: 100, y: 3)]),
            ("M0 0E1", [.move(x: 0, y: 0)]), (" M 0,0\n\tL 10 , 10\r\nZ ", [.move(x: 0, y: 0), .line(x: 10, y: 10), .close])
        ]
        for (data, commands) in cases {
            expect(LayoutPath.commands(data) == commands, "path data \(data.debugDescription) parses, got \(String(describing: LayoutPath.commands(data)))")
        }
        for data in ["", " ", "L1 1", "Z", "M1", "M1 2 3", "M", "M0 0L", "M0 0H", "M0 0C1 2 3 4 5", "M0 0S1 2 3", "M0 0Q1 2 3", "M0 0T1",
                     "M0 0A1 1 0 0 1 2 2", "M0 0a1 1 0 0 1 2 2", "M0 0Z1", "M0 0,Z", "M0 0L1 1,", "M,0 0", "M0,,0", "M1. 2", "M. 2", "M0 0e",
                     "M0 0e+", "M1e5e5 0", "M+-1 2", "M- 1", "M0x10 0", "M0 0\u{00a0}L1 1", "M0 0\u{000c}L1 1", "M\u{0660} \u{0660}", "M0 0 \u{017f}1 2 3 4",
                     "M0 0B1 1", "M1.5.5.5"] {
            expect(LayoutPath.commands(data) == nil, "path data \(data.debugDescription) is invalid")
        }
        expect(LayoutPath.commands("M1e999 0") == nil, "path numbers must be finite to draw")
        try layoutRequest(layoutJSON(lockScreen: #"{"type":"path","d":"M1e999 0","box":[8,8]}"#, values: "{}")).validate()
        expect(true, "validation checks the syntax of path data only")

        let path = try layoutDocument(#"{"type":"hstack","children":[{"type":"path","d":"M0 0L8 8","box":[8,16]},{"type":"path","d":"M0 0L8 8","box":[24,24],"stroke":1.5},{"type":"path","d":"L1 1","box":[8,8]}]}"#)
        expect(children(path.render(.lockScreen, values: [:])).map(\.content) == [
            .path(commands: [.move(x: 0, y: 0), .line(x: 8, y: 8)], width: 8, height: 16, stroke: nil),
            .path(commands: [.move(x: 0, y: 0), .line(x: 8, y: 8)], width: 24, height: 24, stroke: 1.5)], "path box and stroke; invalid data renders nothing")
    }

    @MainActor private static func testRenderStyles() throws {
        let styles = ##"{"named":{"font":"headline","weight":"semibold","design":"rounded","monospacedDigit":true,"color":"secondary","lineLimit":2,"##
            + ##""minimumScaleFactor":0.5,"alignment":"trailing","padding":8,"frame":{"maxWidth":"infinity"},"background":"#FF8000","cornerRadius":12,"##
            + ##""opacity":0.9,"tint":{"light":"#000000","dark":"#ffffff80"},"buttonStyle":"borderedProminent"},"##
            + ##""sized":{"size":15,"padding":[1,2,3,4],"frame":{"width":120,"height":40,"minWidth":80,"minHeight":20,"maxWidth":300,"maxHeight":"infinity","alignment":"topLeading"},"background":"#00000040"},"##
            + ##""odd":{"color":"chartreuse","background":"#12","tint":{"light":"#000000","dark":"red"}}}"##
        let document = try layoutDocument(#"{"type":"text","value":"a","style":"named"}"#, styles: styles)
        let named = document.style("named")
        expect(named.font == .named(.headline) && named.weight == .semibold && named.design == .rounded && named.monospacedDigit, "font members")
        expect(named.color == .semantic(.secondary) && named.lineLimit == 2 && named.minimumScaleFactor == 0.5 && named.alignment == .trailing, "text members")
        expect(named.padding == LayoutEdges(top: 8, leading: 8, bottom: 8, trailing: 8), "one padding number applies to every edge")
        expect(named.frame == LayoutRenderFrame(width: nil, height: nil, minWidth: nil, minHeight: nil, maxWidth: .infinity, maxHeight: nil, alignment: .center),
               "infinity is an unbounded maximum and frames align to the center by default")
        expect(named.background == .fixed(LayoutRGBA(red: 1, green: 128.0 / 255, blue: 0, alpha: 1)) && named.cornerRadius == 12 && named.opacity == 0.9,
               "six hex digits are an opaque color")
        expect(named.tint == .adaptive(light: LayoutRGBA(red: 0, green: 0, blue: 0, alpha: 1), dark: LayoutRGBA(red: 1, green: 1, blue: 1, alpha: 128.0 / 255))
            && named.buttonStyle == .borderedProminent, "a color pair keeps both appearances; hex digits may be lower case")
        expect(document.render(.lockScreen, values: [:])?.style == named, "a node carries its resolved style")
        let sized = document.style("sized")
        expect(sized.font == .size(15) && sized.weight == nil && sized.design == nil && !sized.monospacedDigit && sized.color == nil, "size replaces the font name")
        expect(sized.padding == LayoutEdges(top: 1, leading: 2, bottom: 3, trailing: 4), "four padding numbers are top, leading, bottom, trailing")
        expect(sized.frame == LayoutRenderFrame(width: 120, height: 40, minWidth: 80, minHeight: 20, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading),
               "every frame member")
        expect(sized.background == .fixed(LayoutRGBA(red: 0, green: 0, blue: 0, alpha: 64.0 / 255)), "eight hex digits carry alpha")
        let odd = document.style("odd")
        expect(odd.color == nil && odd.background == nil && odd.tint == nil, "a color outside the contract resolves to nothing")
        let tableless = try layoutDocument(#"{"type":"divider"}"#)
        expect(document.style("absent") == .plain && document.style(nil) == .plain && tableless.style("named") == .plain,
               "an unknown token or an absent table is the plain style")
        expect(LayoutRenderStyle.plain.font == nil && LayoutRenderStyle.plain.padding == nil && LayoutRenderStyle.plain.frame == nil
            && LayoutRenderStyle.plain.lineLimit == nil && LayoutRenderStyle.plain.buttonStyle == nil, "the plain style sets nothing")
        for name in ["primary", "secondary", "accent", "red", "orange", "yellow", "green", "mint", "teal", "cyan", "blue", "indigo", "purple", "pink",
                     "brown", "white", "black", "gray", "clear"] {
            expect(LayoutColorSpec(.single(name)) == LayoutSemanticColor(rawValue: name).map(LayoutColorSpec.semantic), "semantic color \(name)")
        }
        expect(LayoutRGBA(hex: "#ABCDEF") == LayoutRGBA(red: 171.0 / 255, green: 205.0 / 255, blue: 239.0 / 255, alpha: 1)
            && LayoutRGBA(hex: "#abcdef00")?.alpha == 0, "hex digits in either case")
        for hex in ["", "#", "#FFF", "#FFFFF", "#FFFFFFF", "#FFFFFFFFF", "FFFFFF", "#GGGGGG", "#FFFFFF\n", " #FFFFFF", "#\u{0661}\u{0662}\u{0663}\u{0664}\u{0665}\u{0666}"] {
            expect(LayoutRGBA(hex: hex) == nil, "\(hex.debugDescription) is not a hex color")
        }

        let tinted = try layoutDocument(##"{"type":"divider"}"##, layout: ##","background":{"light":"#FFFFFF","dark":"#111111"},"keyline":"accent""##)
        expect(tinted.background == .adaptive(light: LayoutRGBA(red: 1, green: 1, blue: 1, alpha: 1),
                                              dark: LayoutRGBA(red: 17.0 / 255, green: 17.0 / 255, blue: 17.0 / 255, alpha: 1))
            && tinted.keyline == .semantic(.accent), "layout background and keyline")
        let untinted = try layoutDocument(#"{"type":"divider"}"#)
        expect(untinted.background == nil && untinted.keyline == nil, "absent tints stay absent")
    }

    @MainActor private static func testRenderBoundStyles() throws {
        let styles = ##"{"live":{"size":{"bind":"points"},"weight":{"bind":"weight"},"color":{"bind":"tone"},"background":{"bind":"fill"},"##
            + ##""cornerRadius":{"bind":"radius"},"opacity":{"bind":"alpha"},"tint":{"bind":"accent"}}}"##
        let document = try layoutDocument(#"{"type":"text","value":"a","style":"live"}"#, layout: ##","background":{"bind":"paper"},"keyline":{"bind":"edge"}"##,
                                          styles: styles)
        let values: [String: LayoutValue] = ["points": .number(17), "weight": .string("bold"), "tone": .string("red"), "fill": .string("#00000080"),
                                             "radius": .number(8), "alpha": .number(0.5), "accent": .string("mint"), "paper": .string("#FAF7EF"), "edge": .string("orange")]
        let style = document.style("live", values: values)
        expect(style.font == .size(17) && style.weight == .bold && style.color == .semantic(.red)
            && style.background == .fixed(LayoutRGBA(red: 0, green: 0, blue: 0, alpha: 128.0 / 255)) && style.cornerRadius == 8 && style.opacity == 0.5
            && style.tint == .semantic(.mint), "bound members resolve from the values")
        expect(document.render(.lockScreen, values: values)?.style == style, "a node resolves its bound members from the values it is drawn with")
        var later = values
        later["tone"] = .string("#2E8B7A"); later["alpha"] = .number(1); later["weight"] = .string("regular"); later["points"] = .number(96)
        let changed = document.render(.lockScreen, values: later)?.style
        expect(changed?.color == LayoutRGBA(hex: "#2E8B7A").map(LayoutColorSpec.fixed) && changed?.opacity == 1 && changed?.weight == .regular
            && changed?.font == .size(96), "the same node draws the values of the next update")
        expect(document.background(values: values) == LayoutRGBA(hex: "#FAF7EF").map(LayoutColorSpec.fixed)
            && document.keyline(values: values) == .semantic(.orange), "bound tints resolve from the values")
        expect(document.background == nil && document.keyline == nil && document.style("live") == .plain, "without values a bound member is left out")
        let odd: [String: LayoutValue] = ["points": .number(200), "weight": .string("Bold"), "tone": .number(1), "fill": .string("paper"),
                                          "radius": .number(-1), "alpha": .bool(true), "accent": .string(""), "paper": .bool(false), "edge": .string("#FFF")]
        expect(document.style("live", values: odd) == .plain && document.background(values: odd) == nil && document.keyline(values: odd) == nil,
               "a value that a member cannot take leaves the member out")
        expect(document.style("live", values: ["tone": .string("{\"light\":\"#000000\",\"dark\":\"#FFFFFF\"}")]).color == nil,
               "a bound color is never a light and dark pair")
        let literal = try layoutDocument(#"{"type":"text","value":"a","style":"s"}"#, layout: #","keyline":"accent""#, styles: #"{"s":{"opacity":0.25,"color":"red"}}"#)
        expect(literal.keyline(values: [:]) == .semantic(.accent) && literal.keyline == .semantic(.accent) && literal.background(values: values) == nil,
               "a literal tint does not depend on the values")
        expect(literal.style("s", values: values) == literal.style("s") && literal.style("s").opacity == 0.25, "literal members do not depend on the values")
    }

    @MainActor private static func testIslandDefaults() throws {
        func symbolName(_ node: LayoutRenderNode?) -> String? {
            if case let .symbol(name, _, _)? = node?.content { return name } else { return nil }
        }
        let lockScreen = #"{"type":"vstack","children":[{"type":"text","value":"t"},{"type":"hstack","if":"off","children":["#
            + #"{"type":"button","actionId":"a","child":{"type":"symbol","name":"pause.fill","unless":"on","style":"s","rendering":"palette","variableBind":"level"}},{"type":"symbol","name":"timer"}]}]}"#
        let values: [String: LayoutValue] = ["off": .bool(false), "on": .bool(true), "level": .number(0.5)]
        let bare = try layoutDocument(lockScreen, styles: #"{"s":{"color":"red"}}"#)
        expect(texts(bare.render(.expandedBottom, values: values)) == ["t"], "without an island the expanded bottom region shows the lock screen tree")
        expect(bare.render(.expandedLeading, values: values) == nil && bare.render(.expandedTrailing, values: values) == nil
            && bare.render(.expandedCenter, values: values) == nil && bare.render(.compactTrailing, values: values) == nil, "other absent regions are empty")
        for region in [LayoutRegion.compactLeading, .minimal] {
            let node = bare.render(region, values: values)
            expect(node?.content == .symbol(name: "pause.fill", rendering: .palette, variableValue: 0.5) && node?.style.color == .semantic(.red),
                   "\(region) defaults to the first symbol in document order, conditions ignored")
        }
        let symbolless = try layoutDocument(#"{"type":"text","value":"t"}"#)
        expect(symbolName(symbolless.render(.compactLeading, values: [:])) == "circle.fill" && symbolName(symbolless.render(.minimal, values: [:])) == "circle.fill",
               "without a symbol the default is circle.fill")
        expect(symbolless.node(for: .lockScreen) != nil && symbolless.node(for: .compactTrailing) == nil, "regions resolve to nodes")

        let partial = try layoutDocument(lockScreen, layout: #","island":{"minimal":{"type":"symbol","name":"bolt"}}"#, styles: #"{"s":{"color":"red"}}"#)
        expect(symbolName(partial.render(.minimal, values: values)) == "bolt" && symbolName(partial.render(.compactLeading, values: values)) == "pause.fill"
            && texts(partial.render(.expandedBottom, values: values)) == ["t"], "an island without expanded keeps the expanded default")
        let expanded = try layoutDocument(lockScreen, layout: #","island":{"expanded":{"leading":{"type":"symbol","name":"bolt"}},"compactTrailing":{"type":"text","bind":"level"}}"#,
                                          styles: #"{"s":{"color":"red"}}"#)
        expect(symbolName(expanded.render(.expandedLeading, values: values)) == "bolt" && expanded.render(.expandedBottom, values: values) == nil
            && expanded.render(.compactTrailing, values: values)?.content == .text("0.5"), "an expanded island shows only its own regions")
        let full = try layoutRequest(sessionLayout).document
        let sessionValues = try layoutRequest(sessionLayout).snapshot.values
        for region in LayoutRegion.allCases { expect(full.render(region, values: sessionValues) != nil, "session layout renders \(region)") }
        expect(children(full.render(.lockScreen, values: sessionValues)).count == 3, "the session note is hidden and the pause button shown")
    }
}
