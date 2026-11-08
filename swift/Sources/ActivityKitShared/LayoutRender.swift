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

    /// The style of a node without a style token.
    public static let plain = LayoutRenderStyle(nil, values: [:])

    /// Bound members read `values`; a member whose value is missing or does not fit is left out.
    init(_ style: LayoutStyle?, values: [String: LayoutValue]) {
        font = style?.font.map(LayoutRenderFont.named) ?? style?.size?.resolve(values, within: LayoutRules.sizes).map(LayoutRenderFont.size)
        weight = style?.weight?.resolve(values); design = style?.design; fontFamily = style?.fontFamily
        monospacedDigit = style?.monospacedDigit ?? false
        color = style?.color?.resolve(values); lineLimit = style?.lineLimit
        minimumScaleFactor = style?.minimumScaleFactor; alignment = style?.alignment
        switch style?.padding {
        case .all(let value)?: padding = LayoutEdges(top: value, leading: value, bottom: value, trailing: value)
        case .edges(let values)? where values.count == 4: padding = LayoutEdges(top: values[0], leading: values[1], bottom: values[2], trailing: values[3])
        default: padding = nil
        }
        frame = style?.frame.map {
            LayoutRenderFrame(width: $0.width, height: $0.height, minWidth: $0.minWidth, minHeight: $0.minHeight,
                              maxWidth: $0.maxWidth.map { $0.points ?? .infinity }, maxHeight: $0.maxHeight.map { $0.points ?? .infinity },
                              alignment: $0.alignment ?? .center)
        }
        background = style?.background?.resolve(values)
        cornerRadius = style?.cornerRadius?.resolve(values, within: LayoutRules.corners)
        opacity = style?.opacity?.resolve(values, within: LayoutRules.opacities)
        tint = style?.tint?.resolve(values); buttonStyle = style?.buttonStyle
    }
}

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

/// A node resolved against the values: what to draw and with which style.
public struct LayoutRenderNode: Equatable, Sendable {
    public let content: LayoutRenderContent
    public let style: LayoutRenderStyle
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
    /// The first symbol node in document order, whatever its conditions.
    fileprivate var firstSymbol: LayoutNode? {
        switch content {
        case .symbol: return LayoutNode(style: style, content: content)
        case let .vstack(children, _, _), let .hstack(children, _, _), let .zstack(children, _): return children.lazy.compactMap(\.firstSymbol).first
        case let .button(_, child): return child.firstSymbol
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

    /// The tree a region shows: its own, or the default of an absent island part. The expanded island
    /// defaults to the lock screen tree in its bottom region, the compact leading and minimal parts to
    /// the lock screen's first symbol or `circle.fill`, and the compact trailing part to nothing.
    public func node(for region: LayoutRegion) -> LayoutNode? {
        if let node = layout.node(in: region) { return node }
        switch region {
        case .expandedBottom: return layout.island?.expanded == nil ? layout.lockScreen : nil
        case .compactLeading, .minimal:
            return layout.lockScreen.firstSymbol ?? LayoutNode(content: .symbol(name: "circle.fill", rendering: nil, variableBind: nil))
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

    /// A node resolved against the values, or nil when its condition hides it or a value it needs is missing.
    public func render(_ node: LayoutNode, values: [String: LayoutValue]) -> LayoutRenderNode? {
        switch node.condition {
        case .when(let key)?: guard values[key]?.isTruthy == true else { return nil }
        case .unless(let key)?: guard values[key]?.isTruthy != true else { return nil }
        case nil: break
        }
        guard let content = content(of: node.content, values) else { return nil }
        return LayoutRenderNode(content: content, style: style(node.style, values: values))
    }

    private func content(of content: LayoutContent, _ values: [String: LayoutValue]) -> LayoutRenderContent? {
        func visible(_ children: [LayoutNode]) -> [LayoutRenderNode] { children.compactMap { render($0, values: values) } }
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
        case let .button(actionId, child): return render(child, values: values).map { .button(actionId: actionId, label: $0) }
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
            case let .button(_, child): visit(child)
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
