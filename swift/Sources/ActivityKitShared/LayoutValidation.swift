import Foundation

/// Limits, character rules and failures of request contract v2.
enum LayoutRules {
    static let maxRevision: Int64 = 9_007_199_254_740_991
    static let maxTimestamp: Int64 = 8_640_000_000_000_000
    static let maxNumber = 8_640_000_000_000_000.0
    static let maxWeight = 3584
    static let maxDepth = 8
    static let maxButtons = 4
    static let maxProps = 16
    /// The ranges of the numbers that a style member takes, as a literal or bound to a value.
    static let sizes: ClosedRange<Double> = 6...96
    static let opacities: ClosedRange<Double> = 0...1
    static let corners: ClosedRange<Double> = 0...64

    static let request = ActivityFailure("INVALID_INPUT", "Invalid activity key, schema version, or fallback.")
    static let handle = ActivityFailure("INVALID_INPUT", "Invalid activity handle.")
    static let policy = ActivityFailure("INVALID_INPUT", "Invalid dismissal policy.")
    static let snapshot = ActivityFailure("INVALID_INPUT", "Invalid revision or stale timestamp.")
    static let values = ActivityFailure("INVALID_INPUT", "Invalid activity values.")
    static let changed = ActivityFailure("INVALID_INPUT", "Values must keep the keys and types accepted at start.")
    static let layout = ActivityFailure("INVALID_INPUT", "Invalid layout or style.")
    static let limit = ActivityFailure("INVALID_INPUT", "The layout exceeds a structural limit.")
    static let reference = ActivityFailure("INVALID_INPUT", "The layout names a missing value or style, or a value of the wrong type.")
    static let heavy = ActivityFailure("PAYLOAD_TOO_LARGE", "Layout, styles and values exceed the payload weight limit.")

    /// Epoch milliseconds: an integer from 0 to 8640000000000000.
    static func isTime(_ value: Double) -> Bool { value.rounded(.towardZero) == value && (0...maxNumber).contains(value) }

    private static func isLetter(_ byte: UInt8) -> Bool { (0x41...0x5a).contains(byte) || (0x61...0x7a).contains(byte) }
    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private static func isWord(_ byte: UInt8) -> Bool { isLetter(byte) || isDigit(byte) }
    private static func matches(_ text: String, most: Int, first: (UInt8) -> Bool, rest: (UInt8) -> Bool) -> Bool {
        guard let head = text.utf8.first, text.utf8.count <= most, first(head) else { return false }
        return text.utf8.dropFirst().allSatisfy(rest)
    }
    /// A value key or a style token.
    static func isName(_ text: String) -> Bool { matches(text, most: 32, first: isLetter) { isWord($0) || $0 == 0x5f } }
    static func isActivityKey(_ text: String) -> Bool { matches(text, most: 128, first: isWord) { isWord($0) || [0x2e, 0x5f, 0x3a, 0x2d].contains($0) } }
    static func isActionID(_ text: String) -> Bool { matches(text, most: 64, first: isWord) { isWord($0) || [0x2e, 0x5f, 0x3a, 0x2d].contains($0) } }
    /// An asset name, an image file name or the name of a custom view.
    static func isAssetName(_ text: String) -> Bool { matches(text, most: 64, first: isWord) { isWord($0) || [0x2e, 0x5f, 0x2d].contains($0) } }
    /// The PostScript or family name of a font: letters, digits, space, `.`, `_` and `-`.
    static func isFontFamily(_ text: String) -> Bool { matches(text, most: 64, first: isWord) { isWord($0) || [0x20, 0x2e, 0x5f, 0x2d].contains($0) } }
    /// Lower-case words and digits joined by single dots.
    static func isSymbolName(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard (1...64).contains(bytes.count), bytes.first != 0x2e, bytes.last != 0x2e else { return false }
        return bytes.indices.allSatisfy { index in
            isDigit(bytes[index]) || (0x61...0x7a).contains(bytes[index]) || (bytes[index] == 0x2e && bytes[index - 1] != 0x2e)
        }
    }
    /// An opaque handle: 1...256 code points, not only ECMAScript whitespace.
    static func isHandle(_ text: String) -> Bool {
        text.unicodeScalars.count <= 256 && !text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x09...0x0d, 0x20, 0x00a0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff: return true
            default: return false
            }
        }
    }
}

extension LayoutValue {
    private var type: Int {
        switch self {
        case .string: return 0
        case .number: return 1
        case .bool: return 2
        }
    }
    fileprivate var isValid: Bool {
        switch self {
        case .string(let value): return value.unicodeScalars.count <= 1000
        case .number(let value): return (-LayoutRules.maxNumber...LayoutRules.maxNumber).contains(value)
        case .bool: return true
        }
    }
    fileprivate func hasType(of other: LayoutValue?) -> Bool { other?.type == type }
}

extension LayoutSnapshot {
    fileprivate func validateShape() throws {
        guard (0...LayoutRules.maxRevision).contains(revision), staleAt.map((0...LayoutRules.maxTimestamp).contains) ?? true else {
            throw LayoutRules.snapshot
        }
        guard values.count <= 32, values.allSatisfy({ LayoutRules.isName($0.key) && $0.value.isValid }) else { throw LayoutRules.values }
    }
    /// The rules a snapshot can be checked against alone: revision, stale time, values and their weight.
    public func validate() throws {
        try validateShape()
        guard values.wireWeight <= LayoutRules.maxWeight else { throw LayoutRules.heavy }
    }
    /// The rules that need the activity: the keys and types accepted at start, the layout's references and the whole weight.
    public func validate(replacing current: LayoutSnapshot, in document: LayoutDocument) throws {
        guard values.count == current.values.count, values.allSatisfy({ $0.value.hasType(of: current.values[$0.key]) }) else {
            throw LayoutRules.changed
        }
        try document.validateReferences(values)
        guard document.weight + values.wireWeight <= LayoutRules.maxWeight else { throw LayoutRules.heavy }
    }
}

extension LayoutRequest {
    /// Every rule of a layout start. The weight is judged last.
    public func validate() throws {
        guard schemaVersion == 2, ["none", "notification"].contains(fallback), LayoutRules.isActivityKey(activityKey) else {
            throw LayoutRules.request
        }
        try snapshot.validateShape()
        try document.validate()
        try document.validateReferences(snapshot.values)
        guard weight <= LayoutRules.maxWeight else { throw LayoutRules.heavy }
    }
}

extension LayoutUpdateRequest {
    /// The rules of an update that need no activity.
    public func validate() throws {
        guard LayoutRules.isHandle(id) else { throw LayoutRules.handle }
        try snapshot.validate()
    }
}

extension LayoutEndRequest {
    /// The shape of the handle and the policy. The dismissal window is judged when the activity ends.
    public func validate() throws {
        guard LayoutRules.isHandle(id) else { throw LayoutRules.handle }
        if ["immediate", "default"].contains(policy.kind), policy.at == nil { return }
        guard policy.kind == "after", let at = policy.at, (0...LayoutRules.maxTimestamp).contains(at) else { throw LayoutRules.policy }
    }
}

extension LayoutColor {
    fileprivate var isValid: Bool {
        switch self {
        case .single(let value): return LayoutSemanticColor(rawValue: value) != nil || LayoutRGBA(hex: value) != nil
        case let .pair(light, dark): return LayoutRGBA(hex: light) != nil && LayoutRGBA(hex: dark) != nil
        }
    }
}

extension LayoutStyle {
    fileprivate var isValid: Bool {
        let length = 0.0...1024
        let numbers: [(Double?, ClosedRange<Double>)] = [
            (size?.literal, LayoutRules.sizes), (minimumScaleFactor, 0.1...1), (cornerRadius?.literal, LayoutRules.corners),
            (opacity?.literal, LayoutRules.opacities),
            (frame?.width, length), (frame?.height, length), (frame?.minWidth, length), (frame?.minHeight, length),
            (frame?.maxWidth?.points, length), (frame?.maxHeight?.points, length)
        ]
        let sides: [Double]
        switch padding {
        case .all(let value)?: sides = [value]
        case .edges(let values)?: sides = values.count == 4 ? values : [.nan]
        case nil: sides = []
        }
        guard members.contains(where: { $0.value != nil }), font == nil || size == nil,
              fontFamily.map(LayoutRules.isFontFamily) ?? true, fontFamily == nil || design == nil,
              frame?.members.contains(where: { $0.value != nil }) ?? true,
              numbers.allSatisfy({ value, range in value.map(range.contains) ?? true }),
              sides.allSatisfy((0...64).contains), lineLimit.map((1...10).contains) ?? true else { return false }
        return [color, background, tint].allSatisfy { $0?.literal?.isValid ?? true }
    }

    /// Whether every bound member names a value that it can take.
    fileprivate func fits(_ values: [String: LayoutValue]) -> Bool {
        let numbers = [(size, LayoutRules.sizes), (opacity, LayoutRules.opacities), (cornerRadius, LayoutRules.corners)]
        return numbers.allSatisfy { member, range in member?.fits { $0.resolve(values, within: range) } ?? true }
            && weight?.fits { $0.resolve(values) } ?? true
            && [color, background, tint].allSatisfy { member in member?.fits { $0.resolve(values) } ?? true }
    }
}

extension LayoutBindable {
    /// A literal fits; a bound member fits when `resolve` turns its value into what it draws.
    fileprivate func fits<Resolved>(_ resolve: (LayoutBindable) -> Resolved?) -> Bool { key == nil || resolve(self) != nil }
}

extension LayoutDocument {
    private struct Tally { var nodes = 0, buttons = 0 }

    /// The rules of the layout and the style table that need no values.
    func validate() throws {
        if let styles = styles {
            guard (1...24).contains(styles.count), styles.allSatisfy({ LayoutRules.isName($0.key) && $0.value.isValid }) else { throw LayoutRules.layout }
        }
        if let island = layout.island {
            guard island.members.contains(where: { $0.value != nil }),
                  island.expanded?.members.contains(where: { $0.value != nil }) ?? true else { throw LayoutRules.layout }
        }
        guard layout.background?.literal?.isValid ?? true, layout.keyline?.literal?.isValid ?? true else { throw LayoutRules.layout }
        for region in LayoutRegion.allCases {
            var tally = Tally()
            if let root = layout.node(in: region) { try check(root, in: region, depth: 1, inButton: false, tally: &tally) }
        }
    }

    private func check(_ node: LayoutNode, in region: LayoutRegion, depth: Int, inButton: Bool, tally: inout Tally) throws {
        tally.nodes += 1
        guard tally.nodes <= region.mostNodes, depth <= LayoutRules.maxDepth else { throw LayoutRules.limit }
        if let style = node.style, styles?[style] == nil { throw LayoutRules.reference }
        var valid = true
        var children: [LayoutNode] = []
        switch node.content {
        case let .vstack(nodes, spacing, _), let .hstack(nodes, spacing, _):
            (children, valid) = (nodes, (1...12).contains(nodes.count) && spacing.map((0...64).contains) ?? true)
        case let .zstack(nodes, _): (children, valid) = (nodes, (1...12).contains(nodes.count))
        case .spacer(let minLength): valid = minLength.map((0...256).contains) ?? true
        case .text(let value): valid = value.unicodeScalars.count <= 200
        case let .symbol(name, _, _): valid = LayoutRules.isSymbolName(name)
        case let .image(source, _, _): valid = LayoutRules.isAssetName(source.name)
        case let .custom(name, props): valid = LayoutRules.isAssetName(name) && props.map(Self.isValid) ?? true
        case let .path(data, box, stroke):
            valid = (1...512).contains(data.utf8.count) && LayoutPath.isValid(data) && box.count == 2
                && box.allSatisfy((1...1024).contains) && stroke.map((0.5...16).contains) ?? true
        case let .gauge(_, min, max, _): valid = (min ?? 0) < (max ?? 1) && (min ?? 0).isFinite && (max ?? 1).isFinite
        case let .button(actionId, child):
            tally.buttons += 1
            guard tally.buttons <= LayoutRules.maxButtons, region.allowsButtons, !inButton else { throw LayoutRules.limit }
            (children, valid) = ([child], LayoutRules.isActionID(actionId))
        case .divider, .boundText, .progress, .timerText: break
        }
        guard valid else { throw LayoutRules.layout }
        let insideButton: Bool
        if case .button = node.content { insideButton = true } else { insideButton = inButton }
        for child in children { try check(child, in: region, depth: depth + 1, inButton: insideButton, tally: &tally) }
    }

    /// 1 to 16 props under value-key names; a literal is what a value could be, with text of at most 200 code points.
    private static func isValid(_ props: [String: LayoutBindable<LayoutValue>]) -> Bool {
        (1...LayoutRules.maxProps).contains(props.count) && props.allSatisfy { key, prop in
            guard LayoutRules.isName(key) else { return false }
            switch prop {
            case .literal(.string(let text)): return text.unicodeScalars.count <= 200
            case .literal(.number(let number)): return (-LayoutRules.maxNumber...LayoutRules.maxNumber).contains(number)
            case .literal(.bool), .bound: return true
            }
        }
    }

    /// The rules that tie the layout to the values: every named key exists and has the type its node needs;
    /// a `variableBind` number is within 0...1 and timer bounds are times. Every bound member, in every style
    /// whether a node uses it or not, names a value that the member can take.
    func validateReferences(_ values: [String: LayoutValue]) throws {
        let tints = [layout.background, layout.keyline].allSatisfy { tint in tint?.fits { $0.resolve(values) } ?? true }
        guard tints, (styles ?? [:]).values.allSatisfy({ $0.fits(values) }) else { throw LayoutRules.reference }
        for region in LayoutRegion.allCases {
            if let root = layout.node(in: region) { try checkReferences(root, values) }
        }
    }

    private func checkReferences(_ node: LayoutNode, _ values: [String: LayoutValue]) throws {
        var valid = node.condition.map { values[$0.key] != nil } ?? true
        switch node.content {
        case let .vstack(children, _, _), let .hstack(children, _, _), let .zstack(children, _):
            for child in children { try checkReferences(child, values) }
        case .boundText(let key): valid = valid && values[key] != nil
        case let .symbol(_, _, key?): valid = valid && values[key]?.number.map((0...1).contains) == true
        case let .progress(key, _), let .gauge(key, _, _, _): valid = valid && values[key]?.number != nil
        case let .timerText(start, end, _):
            if let from = values[start]?.number, let to = values[end]?.number, LayoutRules.isTime(from), LayoutRules.isTime(to), to > from { break }
            valid = false
        case let .button(_, child): try checkReferences(child, values)
        case let .custom(_, props?): valid = valid && props.values.allSatisfy { $0.key.map { values[$0] != nil } ?? true }
        case .spacer, .divider, .text, .symbol, .image, .path, .custom: break
        }
        guard valid else { throw LayoutRules.reference }
    }
}
