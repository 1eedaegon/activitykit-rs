import Foundation

/// One drawing step of a path, in absolute coordinates of the node's box.
public enum LayoutPathCommand: Equatable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case curve(control1X: Double, control1Y: Double, control2X: Double, control2Y: Double, x: Double, y: Double)
    case close
}

/// SVG path data of the contract: M L H V C S Q T Z in either case, no arcs.
public enum LayoutPath {
    private struct Point { var x = 0.0, y = 0.0 }
    private typealias Segment = (command: UInt8, numbers: [Double])
    private static let arity: [UInt8: Int] = [
        UInt8(ascii: "M"): 2, UInt8(ascii: "L"): 2, UInt8(ascii: "T"): 2, UInt8(ascii: "H"): 1, UInt8(ascii: "V"): 1,
        UInt8(ascii: "C"): 6, UInt8(ascii: "S"): 4, UInt8(ascii: "Q"): 4, UInt8(ascii: "Z"): 0
    ]
    private static func upper(_ byte: UInt8) -> UInt8 { byte >= UInt8(ascii: "a") ? byte - 0x20 : byte }
    private static func isDigit(_ bytes: [UInt8], _ index: Int) -> Bool { index < bytes.count && (0x30...0x39).contains(bytes[index]) }
    private static func isSign(_ bytes: [UInt8], _ index: Int) -> Bool { index < bytes.count && (bytes[index] == 0x2b || bytes[index] == 0x2d) }
    private static func gapEnd(_ bytes: [UInt8], _ start: Int) -> Int {
        var index = start
        while index < bytes.count, [0x20, 0x09, 0x0d, 0x0a].contains(bytes[index]) { index += 1 }
        return index
    }
    /// Where the number that starts at `start` ends: sign, digits with an optional fraction, optional exponent.
    private static func numberEnd(_ bytes: [UInt8], _ start: Int) -> Int? {
        var index = isSign(bytes, start) ? start + 1 : start
        let whole = index
        while isDigit(bytes, index) { index += 1 }
        if index < bytes.count, bytes[index] == 0x2e, isDigit(bytes, index + 1) {
            index += 1
            while isDigit(bytes, index) { index += 1 }
        } else if index == whole { return nil }
        guard index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 else { return index }
        var exponent = isSign(bytes, index + 1) ? index + 2 : index + 1
        guard isDigit(bytes, exponent) else { return index }
        while isDigit(bytes, exponent) { exponent += 1 }
        return exponent
    }

    /// The commands with their arguments, or nil when the text is not path data of the contract.
    private static func segments(_ data: String) -> [Segment]? {
        let bytes = Array(data.utf8)
        var segments: [Segment] = []
        var index = 0
        while index < bytes.count {
            index = gapEnd(bytes, index)
            guard index < bytes.count, let count = arity[upper(bytes[index])] else { return nil }
            let command = bytes[index]
            var numbers: [Double] = []
            var next = gapEnd(bytes, index + 1)
            index = next
            while let end = numberEnd(bytes, next) {
                numbers.append(Double(String(decoding: bytes[next..<end], as: UTF8.self)) ?? .nan)
                index = end
                next = gapEnd(bytes, end)
                if next < bytes.count, bytes[next] == 0x2c { next = gapEnd(bytes, next + 1) }
            }
            index = gapEnd(bytes, index)
            let complete = count == 0 ? numbers.isEmpty : !numbers.isEmpty && numbers.count % count == 0
            guard complete, !segments.isEmpty || upper(command) == UInt8(ascii: "M") else { return nil }
            segments.append((command, numbers))
        }
        return segments.isEmpty ? nil : segments
    }

    /// Whether the text is path data of the contract. Numbers are not required to fit a Double.
    static func isValid(_ data: String) -> Bool { segments(data) != nil }

    /// The drawing commands of the path data, or nil when it is invalid or a coordinate is not finite.
    /// Relative commands are resolved, smooth and quadratic curves become cubic ones.
    public static func commands(_ data: String) -> [LayoutPathCommand]? {
        guard let segments = segments(data) else { return nil }
        var commands: [LayoutPathCommand] = []
        var current = Point(), start = Point()
        var cubic: Point?, quadratic: Point?
        var closed = false
        func curve(_ first: Point, _ second: Point, _ end: Point) -> LayoutPathCommand {
            .curve(control1X: first.x, control1Y: first.y, control2X: second.x, control2Y: second.y, x: end.x, y: end.y)
        }
        func toward(_ from: Point, _ control: Point) -> Point {
            Point(x: from.x + (control.x - from.x) * 2 / 3, y: from.y + (control.y - from.y) * 2 / 3)
        }
        for (command, numbers) in segments {
            let letter = Character(UnicodeScalar(upper(command)))
            guard letter != "Z" else {
                commands.append(.close)
                (current, closed, cubic, quadratic) = (start, true, nil, nil)
                continue
            }
            let relative = command != upper(command)
            for offset in stride(from: 0, to: numbers.count, by: arity[upper(command)] ?? 1) {
                let origin = relative ? current : Point()
                func point(_ at: Int) -> Point { Point(x: origin.x + numbers[offset + at], y: origin.y + numbers[offset + at + 1]) }
                if closed, letter != "M" { commands.append(.move(x: start.x, y: start.y)) }
                closed = false
                var nextCubic: Point?, nextQuadratic: Point?
                switch letter {
                case "M":
                    current = point(0)
                    if offset == 0 { start = current; commands.append(.move(x: current.x, y: current.y)) }
                    else { commands.append(.line(x: current.x, y: current.y)) }
                case "L", "H", "V":
                    if letter == "L" { current = point(0) }
                    else if letter == "H" { current.x = origin.x + numbers[offset] }
                    else { current.y = origin.y + numbers[offset] }
                    commands.append(.line(x: current.x, y: current.y))
                case "C", "S":
                    let first = letter == "C" ? point(0) : cubic.map { Point(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let second = point(letter == "C" ? 2 : 0), end = point(letter == "C" ? 4 : 2)
                    commands.append(curve(first, second, end))
                    (current, nextCubic) = (end, second)
                default:
                    let control = letter == "Q" ? point(0) : quadratic.map { Point(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                    let end = point(letter == "Q" ? 2 : 0)
                    commands.append(curve(toward(current, control), toward(end, control), end))
                    (current, nextQuadratic) = (end, control)
                }
                (cubic, quadratic) = (nextCubic, nextQuadratic)
            }
        }
        return commands.allSatisfy(isFinite) ? commands : nil
    }

    private static func isFinite(_ command: LayoutPathCommand) -> Bool {
        switch command {
        case let .move(x, y), let .line(x, y): return x.isFinite && y.isFinite
        case let .curve(a, b, c, d, x, y): return [a, b, c, d, x, y].allSatisfy(\.isFinite)
        case .close: return true
        }
    }
}
