import Foundation

/// The places a layout activity is drawn in.
public enum LayoutRegion: String, CaseIterable, Sendable {
    case lockScreen, expandedLeading, expandedTrailing, expandedCenter, expandedBottom, compactLeading, compactTrailing, minimal

    var mostNodes: Int {
        switch self {
        case .lockScreen: return 40
        case .expandedLeading, .expandedTrailing, .expandedCenter, .expandedBottom: return 12
        case .compactLeading, .compactTrailing, .minimal: return 3
        }
    }
    /// Whether the region takes buttons, links and toggles.
    var allowsButtons: Bool {
        switch self {
        case .compactLeading, .compactTrailing, .minimal: return false
        default: return true
        }
    }
}

public struct LayoutRGBA: Equatable, Sendable {
    public let red: Double, green: Double, blue: Double, alpha: Double
    /// `#RRGGBB` or `#RRGGBBAA`, hex digits in either case.
    public init?(hex: String) {
        let bytes = Array(hex.utf8)
        guard bytes.first == 0x23, bytes.count == 7 || bytes.count == 9 else { return nil }
        var parts: [Double] = []
        for index in stride(from: 1, to: bytes.count, by: 2) {
            guard let high = LayoutRGBA.digit(bytes[index]), let low = LayoutRGBA.digit(bytes[index + 1]) else { return nil }
            parts.append(Double(high * 16 + low) / 255)
        }
        self.init(red: parts[0], green: parts[1], blue: parts[2], alpha: parts.count == 4 ? parts[3] : 1)
    }
    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    private static func digit(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte) - 0x30
        case 0x41...0x46: return Int(byte) - 0x37
        case 0x61...0x66: return Int(byte) - 0x57
        default: return nil
        }
    }
}

/// A color without a UI framework: a system color, one fixed color, or one per appearance.
public enum LayoutColorSpec: Equatable, Sendable {
    case semantic(LayoutSemanticColor)
    case fixed(LayoutRGBA)
    case adaptive(light: LayoutRGBA, dark: LayoutRGBA)

    /// Nil when the color is outside the contract.
    public init?(_ color: LayoutColor) {
        switch color {
        case .single(let value):
            if let name = LayoutSemanticColor(rawValue: value) { self = .semantic(name) }
            else if let rgba = LayoutRGBA(hex: value) { self = .fixed(rgba) }
            else { return nil }
        case let .pair(light, dark):
            guard let light = LayoutRGBA(hex: light), let dark = LayoutRGBA(hex: dark) else { return nil }
            self = .adaptive(light: light, dark: dark)
        }
    }
}

public enum LayoutRenderFont: Equatable, Sendable {
    case named(LayoutFontName)
    case size(Double)
}
public struct LayoutEdges: Equatable, Sendable {
    public let top: Double, leading: Double, bottom: Double, trailing: Double
}
public struct LayoutRenderFrame: Equatable, Sendable {
    public let width: Double?, height: Double?, minWidth: Double?, minHeight: Double?
    /// `Double.infinity` for an unbounded maximum.
    public let maxWidth: Double?, maxHeight: Double?
    public let alignment: LayoutAnchor
}

/// A style token resolved to what a view applies. Apply in this order: font members, color, tint and
/// buttonStyle, padding, frame, background, cornerRadius, opacity.
public struct LayoutRenderStyle: Equatable, Sendable {
    public let font: LayoutRenderFont?
    public let weight: LayoutFontWeight?
    public let design: LayoutFontDesign?
    /// A font of the widget extension: with `font` at that text style's size, with a `size` at that size.
    public let fontFamily: String?
    public let monospacedDigit: Bool
    public let color: LayoutColorSpec?
    public let lineLimit: Int?
    public let minimumScaleFactor: Double?
    public let alignment: LayoutHorizontalAlignment?
    public let padding: LayoutEdges?
    public let frame: LayoutRenderFrame?
    public let background: LayoutColorSpec?
    public let cornerRadius: Double?
    public let opacity: Double?
    public let tint: LayoutColorSpec?
    public let buttonStyle: LayoutButtonStyle?
    public let contentTransition: LayoutContentTransition?

    /// The style of a node without a style token.
    public static let plain = LayoutRenderStyle(nil, values: [:])

    /// Bound members read `values`; a member whose value is missing or does not fit is left out.
    init(_ style: LayoutStyle?, values: [String: LayoutValue]) {
        font = style?.font.map(LayoutRenderFont.named) ?? style?.size?.resolve(values, within: LayoutRules.sizes).map(LayoutRenderFont.size)
        weight = style?.weight?.resolve(values); design = style?.design; fontFamily = style?.fontFamily
        monospacedDigit = style?.monospacedDigit ?? false
        color = style?.color?.resolve(values); lineLimit = style?.lineLimit
        minimumScaleFactor = style?.minimumScaleFactor; alignment = style?.alignment
        padding = style?.padding?.edges
        frame = style?.frame.map {
            LayoutRenderFrame(width: $0.width, height: $0.height, minWidth: $0.minWidth, minHeight: $0.minHeight,
                              maxWidth: $0.maxWidth.map { $0.points ?? .infinity }, maxHeight: $0.maxHeight.map { $0.points ?? .infinity },
                              alignment: $0.alignment ?? .center)
        }
        background = style?.background?.resolve(values)
        cornerRadius = style?.cornerRadius?.resolve(values, within: LayoutRules.corners)
        opacity = style?.opacity?.resolve(values, within: LayoutRules.opacities)
        tint = style?.tint?.resolve(values); buttonStyle = style?.buttonStyle
        contentTransition = style?.contentTransition
    }
}

extension LayoutPadding {
    /// The four edges, or nil for a list that is not four numbers.
    var edges: LayoutEdges? {
        switch self {
        case .all(let value): return LayoutEdges(top: value, leading: value, bottom: value, trailing: value)
        case .edges(let values) where values.count == 4: return LayoutEdges(top: values[0], leading: values[1], bottom: values[2], trailing: values[3])
        default: return nil
        }
    }
}

/// A presentation of the Dynamic Island, as its margins name it.
public enum LayoutIslandPresentation: Sendable, CaseIterable { case expanded, compactLeading, compactTrailing, minimal }

extension LayoutBindable where Value == Double {
    /// The literal, or the bound value when it is a number within `range`.
    func resolve(_ values: [String: LayoutValue], within range: ClosedRange<Double>) -> Double? {
        switch self {
        case .literal(let value): return value
        case .bound(let key): return values[key]?.number.flatMap { range.contains($0) ? $0 : nil }
        }
    }
}

extension LayoutBindable where Value == LayoutFontWeight {
    /// The literal, or the bound value when it is a weight name.
    func resolve(_ values: [String: LayoutValue]) -> LayoutFontWeight? {
        switch self {
        case .literal(let value): return value
        case .bound(let key): return values[key]?.string.flatMap(LayoutFontWeight.init(rawValue:))
        }
    }
}

extension LayoutBindable where Value == LayoutColor {
    /// The literal, or the bound value when it is a color name or a hex color. A value is never a light and dark pair.
    func resolve(_ values: [String: LayoutValue]) -> LayoutColorSpec? {
        switch self {
        case .literal(let value): return LayoutColorSpec(value)
        case .bound(let key): return values[key]?.string.flatMap { LayoutColorSpec(.single($0)) }
        }
    }
}

extension LayoutBindable where Value == String {
    /// The literal, or the bound value when it is text, as far as it is a URL of the contract.
    func urlText(_ values: [String: LayoutValue]) -> String? {
        let text: String?
        switch self {
        case .literal(let value): text = value
        case .bound(let key): text = values[key]?.string
        }
        return text.flatMap { LayoutRules.isURL($0) ? $0 : nil }
    }
    /// The URL to open, or nil when there is none or the system cannot read it as it is. From iOS 17 the system would
    /// otherwise rewrite what it cannot read, and the app would be opened with another URL than the one sent.
    func url(_ values: [String: LayoutValue]) -> URL? {
        guard let text = urlText(values) else { return nil }
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *) { return URL(string: text, encodingInvalidCharacters: false) }
        return URL(string: text)
    }
}

/// What a node tells assistive technologies, resolved against the values. `combinesChildren` is true for a node that
/// is drawn as several views and has a label, a value or a hint (a stack, a custom view, a link drawn without its
/// URL): it is then one element that stands for what is inside, instead of each view inside taking the label.
public struct LayoutRenderAccessibility: Equatable, Sendable {
    public let label: String?, value: String?, hint: String?
    public let hidden: Bool
    public let combinesChildren: Bool
    /// The node, or one that holds it, is marked sensitive: while the system hides private content, what is drawn is
    /// hidden, and the label, the value and the hint must not be read out either.
    public let isSensitive: Bool
    init(label: String? = nil, value: String? = nil, hint: String? = nil, hidden: Bool = false, combinesChildren: Bool = false,
         isSensitive: Bool = false) {
        self.label = label; self.value = value; self.hint = hint; self.hidden = hidden; self.combinesChildren = combinesChildren
        self.isSensitive = isSensitive
    }
}

extension LayoutAccessibility {
    /// Literals as given and bound members as a text node shows the value; a value that is missing or empty leaves its
    /// member out. Nil when nothing is left to say.
    func resolve(_ values: [String: LayoutValue], combining: Bool, sensitive: Bool = false) -> LayoutRenderAccessibility? {
        if hidden == true { return LayoutRenderAccessibility(hidden: true) }
        func spoken(_ member: LayoutBindable<String>?) -> String? {
            let text: String?
            switch member {
            case .literal(let value)?: text = value
            case .bound(let key)?: text = values[key]?.text
            case nil: text = nil
            }
            return text.flatMap { $0.isEmpty ? nil : $0 }
        }
        let label = spoken(self.label), value = spoken(self.value), hint = spoken(self.hint)
        guard label != nil || value != nil || hint != nil else { return nil }
        return LayoutRenderAccessibility(label: label, value: value, hint: hint, combinesChildren: combining, isSensitive: sensitive)
    }
}

/// A node resolved against the values: what to draw, with which style, what assistive technologies read of it, and
/// how it is presented.
public struct LayoutRenderNode: Equatable, Sendable {
    public let content: LayoutRenderContent
    public let style: LayoutRenderStyle
    public let accessibility: LayoutRenderAccessibility?
    /// How the node comes and goes; nil leaves it to the system.
    public let transition: LayoutTransition?
    public let isSensitive: Bool
    /// The node's place among its siblings in the layout, hidden ones counted: its identity, so that a sibling that
    /// comes or goes is seen as that one coming or going. 0 for a root and for the child of a button or a link.
    public let slot: Int
    init(content: LayoutRenderContent, style: LayoutRenderStyle, accessibility: LayoutRenderAccessibility? = nil,
         transition: LayoutTransition? = nil, isSensitive: Bool = false, slot: Int = 0) {
        self.content = content; self.style = style; self.accessibility = accessibility
        self.transition = transition; self.isSensitive = isSensitive; self.slot = slot
    }
}

public indirect enum LayoutRenderContent: Equatable, Sendable {
    case vstack(children: [LayoutRenderNode], spacing: Double?, alignment: LayoutHorizontalAlignment)
    case hstack(children: [LayoutRenderNode], spacing: Double?, alignment: LayoutVerticalAlignment)
    case zstack(children: [LayoutRenderNode], alignment: LayoutAnchor)
    case spacer(minLength: Double?)
    case divider
    case text(String)
    /// `variableValue` is within 0...1.
    case symbol(name: String, rendering: LayoutSymbolRendering?, variableValue: Double?)
    case image(source: LayoutImageSource, resizable: Bool, contentMode: LayoutContentMode?)
    /// `width` and `height` are the coordinate space of the commands.
    case path(commands: [LayoutPathCommand], width: Double, height: Double, stroke: Double?)
    /// `value` is within 0...1.
    case progress(value: Double, kind: LayoutMeterKind)
    /// `value` is within `range`.
    case gauge(value: Double, range: ClosedRange<Double>, kind: LayoutMeterKind)
    case timer(interval: ClosedRange<Date>, countsDown: Bool)
    case button(actionId: String, label: LayoutRenderNode)
    /// Without a URL, one the values do not hold or the system cannot read, the label is drawn without a link.
    case link(url: URL?, label: LayoutRenderNode)
    /// `isOn` is the flag the switch shows; a tap asks for the opposite.
    case toggle(actionId: String, isOn: Bool, label: LayoutRenderNode)
    /// The props with bound ones read from the values.
    case custom(name: String, props: [String: LayoutValue])
}

extension LayoutValue {
    /// `true`, a number other than 0, a non-empty string.
    public var isTruthy: Bool {
        switch self {
        case .string(let value): return !value.isEmpty
        case .number(let value): return value != 0
        case .bool(let value): return value
        }
    }
    public var number: Double? {
        if case .number(let value) = self { return value } else { return nil }
    }
    public var string: String? {
        if case .string(let value) = self { return value } else { return nil }
    }
    public var flag: Bool? {
        if case .bool(let value) = self { return value } else { return nil }
    }
    /// The value as a text node shows it. Numbers print as JavaScript's `String(number)` does.
    public var text: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            let text = value.description
            if text.hasSuffix(".0") { return value == 0 ? "0" : String(text.dropLast(2)) }
            guard let mark = text.firstIndex(of: "e"), let exponent = Int(text[text.index(after: mark)...]) else { return text }
            let digits = String(text[..<mark].filter { $0 != "." && $0 != "-" })
            let point = exponent + 1
            let body: String
            if point > 21 || point <= -6 {
                let fraction = String(digits.dropFirst())
                body = String(digits.prefix(1)) + (fraction.isEmpty ? "" : "." + fraction) + (point > 0 ? "e+" : "e-") + String(abs(point - 1))
            } else if point <= 0 {
                body = "0." + String(repeating: "0", count: -point) + digits
            } else {
                body = digits + String(repeating: "0", count: max(0, point - digits.count))
            }
            return (value < 0 ? "-" : "") + body
        }
    }
}

extension LayoutRegion {
    /// The region as the options of the expanded island name it; nil for the others.
    var expandedName: LayoutExpandedRegionName? {
        switch self {
        case .expandedLeading: return .leading
        case .expandedTrailing: return .trailing
        case .expandedCenter: return .center
        case .expandedBottom: return .bottom
        default: return nil
        }
    }
}

extension LayoutRegions {
    /// The tree the layout declares for a region.
    func node(in region: LayoutRegion) -> LayoutNode? {
        switch region {
        case .lockScreen: return lockScreen
        case .expandedLeading: return island?.expanded?.leading
        case .expandedTrailing: return island?.expanded?.trailing
        case .expandedCenter: return island?.expanded?.center
        case .expandedBottom: return island?.expanded?.bottom
        case .compactLeading: return island?.compactLeading
        case .compactTrailing: return island?.compactTrailing
        case .minimal: return island?.minimal
        }
    }
}

extension LayoutNode {
    /// The first symbol node in document order, whatever its conditions. It stays as private as it was: sensitive
    /// when it, or a node that holds it, is marked so.
    fileprivate func firstSymbol(sensitive: Bool = false) -> LayoutNode? {
        let sensitive = sensitive || privacy == .sensitive
        switch content {
        case .symbol: return LayoutNode(style: style, accessibility: accessibility, privacy: sensitive ? .sensitive : nil, content: content)
        case let .vstack(children, _, _), let .hstack(children, _, _), let .zstack(children, _):
            return children.lazy.compactMap { $0.firstSymbol(sensitive: sensitive) }.first
        case let .button(_, child), let .link(_, child), let .toggle(_, _, child): return child.firstSymbol(sensitive: sensitive)
        default: return nil
        }
    }
}

extension LayoutDocument {
    /// The literal background tint. A bound one needs the values: use `background(values:)`.
    public var background: LayoutColorSpec? { background(values: [:]) }
    /// The literal keyline tint. A bound one needs the values: use `keyline(values:)`.
    public var keyline: LayoutColorSpec? { keyline(values: [:]) }
    /// The tint behind the lock screen presentation, a bound one read from `values`.
    public func background(values: [String: LayoutValue]) -> LayoutColorSpec? { layout.background?.resolve(values) }
    /// The tint of the Dynamic Island keyline, a bound one read from `values`.
    public func keyline(values: [String: LayoutValue]) -> LayoutColorSpec? { layout.keyline?.resolve(values) }

    /// The URL a tap on the activity opens the app with, a bound one read from `values`; nil without one.
    public func url(values: [String: LayoutValue]) -> URL? { layout.url?.url(values) }

    /// The tree a region shows: its own, or the default of an absent island part. The expanded island
    /// defaults to the lock screen tree in its bottom region, the compact leading and minimal parts to
    /// the lock screen's first symbol or `circle.fill`, and the compact trailing part to nothing.
    public func node(for region: LayoutRegion) -> LayoutNode? {
        if let node = layout.node(in: region) { return node }
        switch region {
        case .expandedBottom: return layout.island?.expanded == nil ? layout.lockScreen : nil
        case .compactLeading, .minimal:
            return layout.lockScreen.firstSymbol() ?? LayoutNode(content: .symbol(name: "circle.fill", rendering: nil, variableBind: nil))
        default: return nil
        }
    }

    /// The style a token names, or the plain style. Bound members read `values`, so a render with the values of an
    /// update draws the new colors and sizes.
    public func style(_ token: String?, values: [String: LayoutValue] = [:]) -> LayoutRenderStyle {
        LayoutRenderStyle(token.flatMap { styles?[$0] }, values: values)
    }

    /// What a region draws for these values, or nil when it draws nothing.
    public func render(_ region: LayoutRegion, values: [String: LayoutValue]) -> LayoutRenderNode? {
        node(for: region).flatMap { render($0, values: values) }
    }

    /// The priority of an expanded region, 0 unless the layout states one.
    public func priority(of region: LayoutRegion) -> Double {
        region.expandedName.flatMap { layout.island?.expanded?.priority?[$0] } ?? 0
    }
    /// Whether an expanded region goes below the camera when it is too wide to stand beside it.
    public func isBelowIfTooWide(_ region: LayoutRegion) -> Bool {
        region.expandedName.map { layout.island?.expanded?.belowIfTooWide?.contains($0) ?? false } ?? false
    }
    /// The margins of a presentation of the Dynamic Island, or nil to keep the system's.
    public func margins(for presentation: LayoutIslandPresentation) -> LayoutEdges? {
        let margins = layout.island?.margins
        switch presentation {
        case .expanded: return margins?.expanded?.edges
        case .compactLeading: return margins?.compactLeading?.edges
        case .compactTrailing: return margins?.compactTrailing?.edges
        case .minimal: return margins?.minimal?.edges
        }
    }

    /// A node resolved against the values, or nil when its condition hides it or a value it needs is missing.
    public func render(_ node: LayoutNode, values: [String: LayoutValue]) -> LayoutRenderNode? { render(node, values: values, slot: 0, held: false) }

    /// `held` says that a node holding this one is marked sensitive.
    private func render(_ node: LayoutNode, values: [String: LayoutValue], slot: Int, held: Bool) -> LayoutRenderNode? {
        switch node.condition {
        case .when(let key)?: guard values[key]?.isTruthy == true else { return nil }
        case .unless(let key)?: guard values[key]?.isTruthy != true else { return nil }
        case nil: break
        }
        let sensitive = held || node.privacy == .sensitive
        guard let content = content(of: node.content, values, held: sensitive) else { return nil }
        let combining: Bool
        switch content {
        case .vstack, .hstack, .zstack, .custom, .link(url: nil, label: _): combining = true
        default: combining = false
        }
        return LayoutRenderNode(content: content, style: style(node.style, values: values),
                                accessibility: node.accessibility?.resolve(values, combining: combining, sensitive: sensitive),
                                transition: node.transition, isSensitive: node.privacy == .sensitive, slot: slot)
    }

    private func content(of content: LayoutContent, _ values: [String: LayoutValue], held: Bool) -> LayoutRenderContent? {
        func visible(_ children: [LayoutNode]) -> [LayoutRenderNode] {
            children.enumerated().compactMap { slot, child in render(child, values: values, slot: slot, held: held) }
        }
        func label(_ child: LayoutNode) -> LayoutRenderNode? { render(child, values: values, slot: 0, held: held) }
        func unit(_ value: Double) -> Double { min(max(value, 0), 1) }
        switch content {
        case let .vstack(children, spacing, alignment): return .vstack(children: visible(children), spacing: spacing, alignment: alignment ?? .center)
        case let .hstack(children, spacing, alignment): return .hstack(children: visible(children), spacing: spacing, alignment: alignment ?? .center)
        case let .zstack(children, alignment): return .zstack(children: visible(children), alignment: alignment ?? .center)
        case .spacer(let minLength): return .spacer(minLength: minLength)
        case .divider: return .divider
        case .text(let value): return .text(value)
        case .boundText(let key): return values[key].map { .text($0.text) }
        case let .symbol(name, rendering, key):
            return .symbol(name: name, rendering: rendering, variableValue: key.flatMap { values[$0]?.number }.map(unit))
        case let .image(source, resizable, contentMode): return .image(source: source, resizable: resizable ?? false, contentMode: contentMode)
        case let .path(data, box, stroke):
            guard box.count == 2, let commands = LayoutPath.commands(data) else { return nil }
            return .path(commands: commands, width: box[0], height: box[1], stroke: stroke)
        case let .progress(key, kind): return values[key]?.number.map { .progress(value: unit($0), kind: kind ?? .linear) }
        case let .gauge(key, min, max, kind):
            let lower = min ?? 0, upper = max ?? 1
            guard let value = values[key]?.number, lower < upper else { return nil }
            return .gauge(value: Swift.min(Swift.max(value, lower), upper), range: lower...upper, kind: kind ?? .linear)
        case let .timerText(start, end, countsDown):
            guard let from = values[start]?.number, let to = values[end]?.number, to > from else { return nil }
            return .timer(interval: Date(timeIntervalSince1970: from / 1000)...Date(timeIntervalSince1970: to / 1000), countsDown: countsDown ?? true)
        case let .button(actionId, child): return label(child).map { .button(actionId: actionId, label: $0) }
        case let .link(url, child): return label(child).map { .link(url: url.url(values), label: $0) }
        case let .toggle(actionId, key, child):
            guard let isOn = values[key]?.flag else { return nil }
            return label(child).map { .toggle(actionId: actionId, isOn: isOn, label: $0) }
        case let .custom(name, props):
            let resolved = (props ?? [:]).compactMapValues { prop -> LayoutValue? in
                switch prop {
                case .literal(let value): return value
                case .bound(let key): return values[key]
                }
            }
            return .custom(name: name, props: resolved)
        }
    }

    /// The names of the custom views of every region, in document order, each once.
    public var customViewNames: [String] {
        var names: [String] = []
        func visit(_ node: LayoutNode) {
            switch node.content {
            case let .vstack(children, _, _), let .hstack(children, _, _), let .zstack(children, _): children.forEach(visit)
            case let .button(_, child), let .link(_, child), let .toggle(_, _, child): visit(child)
            case let .custom(name, _): if !names.contains(name) { names.append(name) }
            default: break
            }
        }
        LayoutRegion.allCases.compactMap(layout.node(in:)).forEach(visit)
        return names
    }

    /// `layout.custom.<name>` for every custom view of the layout that `registered` lacks; every one of them when
    /// the app has no registry. The widget draws nothing for such a node.
    public func unknownCustomViews(registered: Set<String>?) -> [String] {
        customViewNames.filter { !(registered?.contains($0) ?? false) }.map { "layout.custom.\($0)" }
    }
}
