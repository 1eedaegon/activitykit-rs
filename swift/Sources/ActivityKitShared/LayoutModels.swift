import Foundation

public enum LayoutHorizontalAlignment: String, Codable, Sendable, LayoutWire { case leading, center, trailing }
public enum LayoutVerticalAlignment: String, Codable, Sendable, LayoutWire { case top, center, bottom, firstTextBaseline }
public enum LayoutAnchor: String, Codable, Sendable, LayoutWire {
    case center, leading, trailing, top, bottom, topLeading, topTrailing, bottomLeading, bottomTrailing
}
public enum LayoutSymbolRendering: String, Codable, Sendable, LayoutWire { case monochrome, hierarchical, palette, multicolor }
public enum LayoutContentMode: String, Codable, Sendable, LayoutWire { case fit, fill }
public enum LayoutMeterKind: String, Codable, Sendable, LayoutWire { case linear, circular }
public enum LayoutFontName: String, Codable, Sendable, LayoutWire {
    case largeTitle, title, title2, title3, headline, subheadline, body, callout, footnote, caption, caption2
}
public enum LayoutFontWeight: String, Codable, Sendable, LayoutWire {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black
}
public enum LayoutFontDesign: String, Codable, Sendable, LayoutWire { case `default`, rounded, serif, monospaced }
public enum LayoutButtonStyle: String, Codable, Sendable, LayoutWire { case automatic, bordered, borderedProminent, plain }
public enum LayoutSemanticColor: String, Codable, Sendable {
    case primary, secondary, accent, red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, white, black, gray, clear
}

/// One entry of the values map: a string, a number or a boolean.
public enum LayoutValue: Codable, Hashable, Sendable, LayoutWire {
    case string(String)
    case number(Double)
    case bool(Bool)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { self = .number(try container.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
    /// Match the wire contract: strings are equal when their UTF-8 bytes are.
    public static func == (lhs: LayoutValue, rhs: LayoutValue) -> Bool {
        switch (lhs, rhs) {
        case let (.string(left), .string(right)): return left.utf8.elementsEqual(right.utf8)
        case let (.number(left), .number(right)): return left == right
        case let (.bool(left), .bool(right)): return left == right
        default: return false
        }
    }
    var wireWeight: Int {
        switch self {
        case .string(let value): return value.wireWeight
        case .number(let value): return value.wireWeight
        case .bool(let value): return value.wireWeight
        }
    }
}

/// The content state of a layout activity.
public struct LayoutSnapshot: Codable, Hashable, Sendable {
    public let revision: Int64
    public let values: [String: LayoutValue]
    public let staleAt: Int64?
    public init(revision: Int64, values: [String: LayoutValue], staleAt: Int64? = nil) {
        self.revision = revision; self.values = values; self.staleAt = staleAt
    }
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        revision = try object.need("revision"); values = try object.need("values"); staleAt = try object.take("staleAt")
        try object.finish()
    }
}

/// A semantic name or a hex string, or one hex string per appearance.
public enum LayoutColor: Codable, Sendable, Equatable, LayoutWire {
    case single(String)
    case pair(light: String, dark: String)

    public init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) { self = .single(value); return }
        var object = try LayoutReader(decoder)
        self = .pair(light: try object.need("light"), dark: try object.need("dark"))
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .single(let value): try value.encode(to: encoder)
        case let .pair(light, dark): try LayoutColorPair(light: light, dark: dark).encodeMembers(to: encoder)
        }
    }
    var wireWeight: Int {
        switch self {
        case .single(let value): return value.wireWeight
        case let .pair(light, dark): return LayoutColorPair(light: light, dark: dark).wireWeight
        }
    }
}
private struct LayoutColorPair: LayoutObject {
    let light: String, dark: String
    var members: LayoutMembers { [("light", light), ("dark", dark)] }
    func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
}

/// A literal, or the key of a value that the member reads on every render: `{"bind": "<key>"}` on the wire.
/// The members that can be bound are `color`, `background`, `tint`, `opacity`, `size`, `weight` and `cornerRadius`
/// of a style, and the `background` and `keyline` of a layout.
public enum LayoutBindable<Value: Codable & Sendable>: Codable, Sendable {
    case literal(Value)
    case bound(String)

    public init(from decoder: Decoder) throws {
        if let binding = try? LayoutBinding(from: decoder) { self = .bound(binding.bind); return }
        self = .literal(try Value(from: decoder))
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .literal(let value): try value.encode(to: encoder)
        case .bound(let key): try LayoutBinding(bind: key).encodeMembers(to: encoder)
        }
    }
    /// The literal, or nil when the member is bound.
    public var literal: Value? {
        if case .literal(let value) = self { return value } else { return nil }
    }
    /// The value key, or nil when the member is a literal.
    public var key: String? {
        if case .bound(let key) = self { return key } else { return nil }
    }
}
extension LayoutBindable: Equatable where Value: Equatable {}
extension LayoutBindable: LayoutWire where Value: LayoutWire {
    var wireWeight: Int {
        switch self {
        case .literal(let value): return value.wireWeight
        case .bound(let key): return LayoutBinding(bind: key).wireWeight
        }
    }
}
private struct LayoutBinding: Decodable, LayoutObject {
    let bind: String
    init(bind: String) { self.bind = bind }
    init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        bind = try object.need("bind")
        try object.finish()
    }
    var members: LayoutMembers { [("bind", bind)] }
    func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
}

/// One number for every edge, or top, leading, bottom, trailing.
public enum LayoutPadding: Codable, Sendable, LayoutWire {
    case all(Double)
    case edges([Double])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .all(value) } else { self = .edges(try container.decode([Double].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .all(let value): try value.encode(to: encoder)
        case .edges(let values): try values.encode(to: encoder)
        }
    }
    var wireWeight: Int {
        switch self {
        case .all(let value): return value.wireWeight
        case .edges(let values): return values.wireWeight
        }
    }
}

/// A frame maximum: points, or the word "infinity".
public enum LayoutLength: Codable, Sendable, LayoutWire {
    case points(Double)
    case infinity
    static let word = "infinity"
    var points: Double? {
        if case .points(let value) = self { return value } else { return nil }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Double.self) { self = .points(value); return }
        guard try container.decode(String.self) == LayoutLength.word else { throw LayoutReader.mismatch }
        self = .infinity
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .points(let value): try value.encode(to: encoder)
        case .infinity: try LayoutLength.word.encode(to: encoder)
        }
    }
    var wireWeight: Int {
        switch self {
        case .points(let value): return value.wireWeight
        case .infinity: return LayoutLength.word.wireWeight
        }
    }
}

public struct LayoutFrame: Codable, Sendable, LayoutObject {
    public let width: Double?, height: Double?, minWidth: Double?, minHeight: Double?
    public let maxWidth: LayoutLength?, maxHeight: LayoutLength?
    public let alignment: LayoutAnchor?

    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        width = try object.take("width"); height = try object.take("height")
        minWidth = try object.take("minWidth"); minHeight = try object.take("minHeight")
        maxWidth = try object.take("maxWidth"); maxHeight = try object.take("maxHeight")
        alignment = try object.take("alignment")
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
    var members: LayoutMembers {
        [("width", width), ("height", height), ("minWidth", minWidth), ("minHeight", minHeight),
         ("maxWidth", maxWidth), ("maxHeight", maxHeight), ("alignment", alignment)]
    }
}

/// One entry of the style table. The members of type `LayoutBindable` may name a value; the others are fixed at start.
public struct LayoutStyle: Codable, Sendable, LayoutObject {
    public let font: LayoutFontName?
    public let size: LayoutBindable<Double>?
    public let weight: LayoutBindable<LayoutFontWeight>?
    public let design: LayoutFontDesign?
    /// The PostScript or family name of a font that the widget extension bundles.
    public let fontFamily: String?
    public let monospacedDigit: Bool?
    public let color: LayoutBindable<LayoutColor>?
    public let lineLimit: Int?
    public let minimumScaleFactor: Double?
    public let alignment: LayoutHorizontalAlignment?
    public let padding: LayoutPadding?
    public let frame: LayoutFrame?
    public let background: LayoutBindable<LayoutColor>?
    public let cornerRadius: LayoutBindable<Double>?
    public let opacity: LayoutBindable<Double>?
    public let tint: LayoutBindable<LayoutColor>?
    public let buttonStyle: LayoutButtonStyle?

    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        font = try object.take("font"); size = try object.take("size"); weight = try object.take("weight")
        design = try object.take("design"); fontFamily = try object.take("fontFamily")
        monospacedDigit = try object.take("monospacedDigit"); color = try object.take("color")
        lineLimit = try object.take("lineLimit"); minimumScaleFactor = try object.take("minimumScaleFactor")
        alignment = try object.take("alignment"); padding = try object.take("padding"); frame = try object.take("frame")
        background = try object.take("background"); cornerRadius = try object.take("cornerRadius"); opacity = try object.take("opacity")
        tint = try object.take("tint"); buttonStyle = try object.take("buttonStyle")
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
    var members: LayoutMembers {
        let text: LayoutMembers = [("font", font), ("size", size), ("weight", weight), ("design", design), ("fontFamily", fontFamily),
                                   ("monospacedDigit", monospacedDigit), ("color", color), ("lineLimit", lineLimit),
                                   ("minimumScaleFactor", minimumScaleFactor), ("alignment", alignment)]
        let box: LayoutMembers = [("padding", padding), ("frame", frame), ("background", background), ("cornerRadius", cornerRadius),
                                  ("opacity", opacity), ("tint", tint), ("buttonStyle", buttonStyle)]
        return text + box
    }
}

/// Renders a node only when the named value is truthy (`when`, the wire member `if`) or not truthy.
public enum LayoutCondition: Sendable {
    case when(String)
    case unless(String)
    public var key: String {
        switch self {
        case .when(let key), .unless(let key): return key
        }
    }
}

/// A node's own members. `text` holds a literal value, `boundText` the value key of a text node with `bind`.
public indirect enum LayoutContent: Sendable {
    case vstack(children: [LayoutNode], spacing: Double?, alignment: LayoutHorizontalAlignment?)
    case hstack(children: [LayoutNode], spacing: Double?, alignment: LayoutVerticalAlignment?)
    case zstack(children: [LayoutNode], alignment: LayoutAnchor?)
    case spacer(minLength: Double?)
    case divider
    case text(String)
    case boundText(String)
    case symbol(name: String, rendering: LayoutSymbolRendering?, variableBind: String?)
    case image(source: LayoutImageSource, resizable: Bool?, contentMode: LayoutContentMode?)
    case path(d: String, box: [Double], stroke: Double?)
    case progress(bind: String, kind: LayoutMeterKind?)
    case gauge(bind: String, min: Double?, max: Double?, kind: LayoutMeterKind?)
    case timerText(start: String, end: String, countsDown: Bool?)
    case button(actionId: String, child: LayoutNode)
    /// A view the app registers under `name` in its widget extension. Each prop is a literal or bound to a value.
    case custom(name: String, props: [String: LayoutBindable<LayoutValue>]?)
}

private enum LayoutNodeType: String, Decodable {
    case vstack, hstack, zstack, spacer, divider, text, symbol, image, path, progress, gauge, timerText, button, custom
}

/// Where an image comes from: the asset catalog of the widget extension (`{"asset": name}`), or a PNG that the app
/// wrote into the App Group container (`{"file": name}`).
public enum LayoutImageSource: Codable, Sendable, Equatable, LayoutObject {
    case asset(String)
    case file(String)

    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        let asset: String? = try object.take("asset"), file: String? = try object.take("file")
        switch (asset, file) {
        case let (asset?, nil): self = .asset(asset)
        case let (nil, file?): self = .file(file)
        default: throw LayoutReader.mismatch
        }
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
    /// The asset name or the file name.
    public var name: String {
        switch self {
        case .asset(let name), .file(let name): return name
        }
    }
    var members: LayoutMembers {
        switch self {
        case .asset(let name): return [("asset", name)]
        case .file(let name): return [("file", name)]
        }
    }
}

/// One node of a layout tree.
public struct LayoutNode: Codable, Sendable, LayoutObject {
    public let style: String?
    public let condition: LayoutCondition?
    public let content: LayoutContent
    init(style: String? = nil, condition: LayoutCondition? = nil, content: LayoutContent) {
        self.style = style; self.condition = condition; self.content = content
    }

    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        let type: LayoutNodeType = try object.need("type")
        style = try object.take("style")
        let when: String? = try object.take("if"), unless: String? = try object.take("unless")
        guard when == nil || unless == nil else { throw LayoutReader.mismatch }
        condition = when.map(LayoutCondition.when) ?? unless.map(LayoutCondition.unless)
        switch type {
        case .vstack: content = .vstack(children: try object.need("children"), spacing: try object.take("spacing"), alignment: try object.take("alignment"))
        case .hstack: content = .hstack(children: try object.need("children"), spacing: try object.take("spacing"), alignment: try object.take("alignment"))
        case .zstack: content = .zstack(children: try object.need("children"), alignment: try object.take("alignment"))
        case .spacer: content = .spacer(minLength: try object.take("minLength"))
        case .divider: content = .divider
        case .text:
            let value: String? = try object.take("value"), bind: String? = try object.take("bind")
            switch (value, bind) {
            case let (value?, nil): content = .text(value)
            case let (nil, bind?): content = .boundText(bind)
            default: throw LayoutReader.mismatch
            }
        case .symbol: content = .symbol(name: try object.need("name"), rendering: try object.take("rendering"), variableBind: try object.take("variableBind"))
        case .image:
            content = .image(source: try object.need("source"), resizable: try object.take("resizable"), contentMode: try object.take("contentMode"))
        case .path: content = .path(d: try object.need("d"), box: try object.need("box"), stroke: try object.take("stroke"))
        case .progress: content = .progress(bind: try object.need("bind"), kind: try object.take("kind"))
        case .gauge: content = .gauge(bind: try object.need("bind"), min: try object.take("min"), max: try object.take("max"), kind: try object.take("kind"))
        case .timerText: content = .timerText(start: try object.need("start"), end: try object.need("end"), countsDown: try object.take("countsDown"))
        case .button: content = .button(actionId: try object.need("actionId"), child: try object.need("child"))
        case .custom: content = .custom(name: try object.need("name"), props: try object.take("props"))
        }
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }

    var members: LayoutMembers {
        var when: String?, unless: String?
        switch condition {
        case .when(let key)?: when = key
        case .unless(let key)?: unless = key
        case nil: break
        }
        let (type, own) = contentMembers
        let common: LayoutMembers = [("type", type), ("style", style), ("if", when), ("unless", unless)]
        return common + own
    }
    private var contentMembers: (type: String, own: LayoutMembers) {
        switch content {
        case let .vstack(children, spacing, alignment): return ("vstack", [("children", children), ("spacing", spacing), ("alignment", alignment)])
        case let .hstack(children, spacing, alignment): return ("hstack", [("children", children), ("spacing", spacing), ("alignment", alignment)])
        case let .zstack(children, alignment): return ("zstack", [("children", children), ("alignment", alignment)])
        case .spacer(let minLength): return ("spacer", [("minLength", minLength)])
        case .divider: return ("divider", [])
        case .text(let value): return ("text", [("value", value)])
        case .boundText(let bind): return ("text", [("bind", bind)])
        case let .symbol(name, rendering, variableBind): return ("symbol", [("name", name), ("rendering", rendering), ("variableBind", variableBind)])
        case let .image(source, resizable, contentMode):
            return ("image", [("source", source), ("resizable", resizable), ("contentMode", contentMode)])
        case let .path(d, box, stroke): return ("path", [("d", d), ("box", box), ("stroke", stroke)])
        case let .progress(bind, kind): return ("progress", [("bind", bind), ("kind", kind)])
        case let .gauge(bind, min, max, kind): return ("gauge", [("bind", bind), ("min", min), ("max", max), ("kind", kind)])
        case let .timerText(start, end, countsDown): return ("timerText", [("start", start), ("end", end), ("countsDown", countsDown)])
        case let .button(actionId, child): return ("button", [("actionId", actionId), ("child", child)])
        case let .custom(name, props): return ("custom", [("name", name), ("props", props)])
        }
    }
}

/// The expanded Dynamic Island: at least one region.
public struct LayoutExpandedIsland: Codable, Sendable, LayoutObject {
    public let leading: LayoutNode?, trailing: LayoutNode?, center: LayoutNode?, bottom: LayoutNode?
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        leading = try object.take("leading"); trailing = try object.take("trailing")
        center = try object.take("center"); bottom = try object.take("bottom")
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
    var members: LayoutMembers { [("leading", leading), ("trailing", trailing), ("center", center), ("bottom", bottom)] }
}

/// The Dynamic Island: at least one part.
public struct LayoutIsland: Codable, Sendable, LayoutObject {
    public let expanded: LayoutExpandedIsland?
    public let compactLeading: LayoutNode?, compactTrailing: LayoutNode?, minimal: LayoutNode?
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        expanded = try object.take("expanded"); compactLeading = try object.take("compactLeading")
        compactTrailing = try object.take("compactTrailing"); minimal = try object.take("minimal")
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
    var members: LayoutMembers {
        [("expanded", expanded), ("compactLeading", compactLeading), ("compactTrailing", compactTrailing), ("minimal", minimal)]
    }
}

/// The wire member `layout`: one tree per region and the two tints.
public struct LayoutRegions: Codable, Sendable, LayoutObject {
    public let lockScreen: LayoutNode
    public let island: LayoutIsland?
    public let background: LayoutBindable<LayoutColor>?, keyline: LayoutBindable<LayoutColor>?
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        lockScreen = try object.need("lockScreen"); island = try object.take("island")
        background = try object.take("background"); keyline = try object.take("keyline")
        try object.finish()
    }
    public func encode(to encoder: Encoder) throws { try encodeMembers(to: encoder) }
    var members: LayoutMembers { [("lockScreen", lockScreen), ("island", island), ("background", background), ("keyline", keyline)] }
}

/// What an activity keeps for its whole life: the layout and the style table.
public struct LayoutDocument: Codable, Sendable {
    public let layout: LayoutRegions
    public let styles: [String: LayoutStyle]?
    init(layout: LayoutRegions, styles: [String: LayoutStyle]?) { self.layout = layout; self.styles = styles }
    public init(from decoder: Decoder) throws {
        var object = try LayoutReader(decoder)
        layout = try object.need("layout"); styles = try object.take("styles")
        try object.finish()
    }
    /// Payload weight of the layout plus the style table (an absent table weighs as `{}`).
    public var weight: Int { layout.wireWeight + (styles?.wireWeight ?? 2) }
}
