import XCTest

/// A color of a screenshot.
struct RGB: Equatable, CustomStringConvertible {
    let red: Int
    let green: Int
    let blue: Int

    init(_ red: Int, _ green: Int, _ blue: Int) {
        self.red = red; self.green = green; self.blue = blue
    }

    /// Whether the two are one color of a layout: a screenshot holds a color to within a few steps of a channel.
    func isNear(_ other: RGB) -> Bool {
        let steps = 12
        return abs(red - other.red) <= steps && abs(green - other.green) <= steps && abs(blue - other.blue) <= steps
    }

    var description: String { "(\(red), \(green), \(blue))" }
}

/// A screenshot as its pixels, read by parts given in the points of the screen.
struct Pixels {
    private let bytes: [UInt8]
    private let width: Int
    private let height: Int
    /// Pixels in a point.
    let scale: CGFloat

    /// `screen` is the size of the screen in points.
    init?(_ screenshot: XCUIScreenshot, screen: CGSize) {
        guard let image = screenshot.image.cgImage, screen.width > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
        width = image.width
        height = image.height
        scale = CGFloat(image.width) / screen.width
    }

    private func color(_ column: Int, _ row: Int) -> RGB {
        let at = (row * width + column) * 4
        return RGB(Int(bytes[at]), Int(bytes[at + 1]), Int(bytes[at + 2]))
    }

    /// The pixel that holds a point of the screen, if the screenshot has it.
    private func pixel(_ point: CGPoint) -> (column: Int, row: Int)? {
        let column = Int((point.x * scale).rounded(.down)), row = Int((point.y * scale).rounded(.down))
        return column >= 0 && row >= 0 && column < width && row < height ? (column, row) : nil
    }

    /// The part of the screen that the pixels from one corner to the other cover.
    private func frame(_ columns: ClosedRange<Int>, _ rows: ClosedRange<Int>) -> CGRect {
        CGRect(x: CGFloat(columns.lowerBound) / scale, y: CGFloat(rows.lowerBound) / scale,
               width: CGFloat(columns.count) / scale, height: CGFloat(rows.count) / scale)
    }

    /// Whether the two screenshots are the same, pixel for pixel.
    func isSame(as other: Pixels) -> Bool {
        bytes == other.bytes
    }

    /// The color at a point of the screen.
    func color(at point: CGPoint) -> RGB? {
        pixel(point).map { color($0.column, $0.row) }
    }

    /// The color of the pair that the average of `part` is nearest to, if it is near one at all.
    func color(in part: CGRect, light: (Int, Int, Int), dark: (Int, Int, Int)) -> PairColor {
        let columns = max(0, Int(part.minX * scale))..<min(width, Int(part.maxX * scale))
        let rows = max(0, Int(part.minY * scale))..<min(height, Int(part.maxY * scale))
        guard !columns.isEmpty, !rows.isEmpty else { return .neither(red: -1, green: -1, blue: -1) }
        var sums = (0, 0, 0)
        for row in rows {
            for column in columns {
                let at = (row * width + column) * 4
                sums = (sums.0 + Int(bytes[at]), sums.1 + Int(bytes[at + 1]), sums.2 + Int(bytes[at + 2]))
            }
        }
        let count = columns.count * rows.count
        let mean = (sums.0 / count, sums.1 / count, sums.2 / count)
        func distance(_ color: (Int, Int, Int)) -> Int {
            abs(mean.0 - color.0) + abs(mean.1 - color.1) + abs(mean.2 - color.2)
        }
        // A third of the way between the two colors of a pair that differ in every channel.
        let near = 250
        if distance(light) < near { return .light }
        if distance(dark) < near { return .dark }
        return .neither(red: mean.0, green: mean.1, blue: mean.2)
    }

    /// The first point with `color` at or left of `point`, in its row of pixels.
    func nearest(_ wanted: RGB, leftOf point: CGPoint) -> CGPoint? {
        guard let start = pixel(point) else { return nil }
        return stride(from: start.column, through: 0, by: -1).first { color($0, start.row).isNear(wanted) }
            .map { CGPoint(x: (CGFloat($0) + 0.5) / scale, y: point.y) }
    }

    /// How many pixels of `wanted` there are inside `part`.
    func count(of wanted: RGB, in part: CGRect) -> Int {
        let columns = max(0, Int(part.minX * scale))..<min(width, Int(part.maxX * scale))
        let rows = max(0, Int(part.minY * scale))..<min(height, Int(part.maxY * scale))
        return rows.reduce(0) { sum, row in sum + columns.filter { color($0, row).isNear(wanted) }.count }
    }

    /// The part of the screen that every pixel of `wanted` inside `part` spans, whether they hang together or not: the
    /// letters of a word; nil without one.
    func span(of wanted: RGB, in part: CGRect) -> CGRect? {
        let columns = max(0, Int(part.minX * scale))..<min(width, Int(part.maxX * scale))
        let rows = max(0, Int(part.minY * scale))..<min(height, Int(part.maxY * scale))
        var left = Int.max, right = Int.min, top = Int.max, bottom = Int.min
        for row in rows {
            for column in columns where color(column, row).isNear(wanted) {
                left = min(left, column); right = max(right, column); top = min(top, row); bottom = max(bottom, row)
            }
        }
        return left <= right ? frame(left...right, top...bottom) : nil
    }

    /// The pixels of the color at `seed` that hang together with it, side by side or one above the other: the part
    /// of the screen they span, and how many they are. A card of one color is such a region, whatever lies on it.
    func region(around seed: CGPoint) -> (frame: CGRect, pixels: Int)? {
        guard let start = pixel(seed) else { return nil }
        let wanted = color(start.column, start.row)
        var visited = [Bool](repeating: false, count: width * height)
        let patch = patch(at: start, in: (0..<width, 0..<height), visited: &visited) { color($0, $1).isNear(wanted) }
        return (frame(patch.columns, patch.rows), patch.count)
    }

    /// For each of `colors`, in their order, the largest patch of it inside `part`: the part of the screen its
    /// pixels span and how many they are, or nil without one. A patch is pixels of one color that hang together,
    /// side by side or one above the other. A box of a layout is one patch; a wallpaper that happens to have a box's
    /// color beside the card's rounded corner is another, smaller than any box the scenarios draw.
    func largest(of colors: [RGB], in part: CGRect) -> [(frame: CGRect, pixels: Int)?] {
        let columns = max(0, Int((part.minX * scale).rounded()))..<min(width, Int((part.maxX * scale).rounded()))
        let rows = max(0, Int((part.minY * scale).rounded()))..<min(height, Int((part.maxY * scale).rounded()))
        var found = [(columns: ClosedRange<Int>, rows: ClosedRange<Int>, count: Int)?](repeating: nil, count: colors.count)
        guard !columns.isEmpty, !rows.isEmpty else { return found.map { _ in nil } }
        var visited = [Bool](repeating: false, count: width * height)
        for row in rows {
            for column in columns where !visited[row * width + column] {
                let seen = color(column, row)
                guard let index = colors.firstIndex(where: { seen.isNear($0) }) else { continue }
                let patch = patch(at: (column, row), in: (columns, rows), visited: &visited) { color($0, $1).isNear(colors[index]) }
                if patch.count > found[index]?.count ?? 0 { found[index] = patch }
            }
        }
        return found.map { patch in patch.map { (frame($0.columns, $0.rows), $0.count) } }
    }

    /// The pixels inside `bounds` that hang together with the one at `start` and that `matches` takes: the columns
    /// and rows they span and their number. Every pixel it reaches is marked in `visited`, one flag for each pixel
    /// of the screenshot.
    private func patch(at start: (column: Int, row: Int), in bounds: (columns: Range<Int>, rows: Range<Int>), visited: inout [Bool],
                       matches: (Int, Int) -> Bool) -> (columns: ClosedRange<Int>, rows: ClosedRange<Int>, count: Int) {
        var open = [start]
        visited[start.row * width + start.column] = true
        var left = start.column, right = start.column, top = start.row, bottom = start.row, count = 0
        func visit(_ column: Int, _ row: Int) {
            guard bounds.columns.contains(column), bounds.rows.contains(row), !visited[row * width + column], matches(column, row) else { return }
            visited[row * width + column] = true
            open.append((column, row))
        }
        while let (column, row) = open.popLast() {
            left = min(left, column); right = max(right, column); top = min(top, row); bottom = max(bottom, row)
            count += 1
            visit(column + 1, row)
            visit(column - 1, row)
            visit(column, row + 1)
            visit(column, row - 1)
        }
        return (left...right, top...bottom, count)
    }

    /// From where to where the pixels above and below `point`, in its column, have one of `colors`. One pixel of
    /// another color between two of them is passed over: where two boxes meet off the pixel grid, the pixel between
    /// them holds a mix of their colors.
    func column(through point: CGPoint, of colors: [RGB]) -> ClosedRange<CGFloat>? {
        guard let start = pixel(point) else { return nil }
        func known(_ row: Int) -> Bool { row >= 0 && row < height && colors.contains { color(start.column, row).isNear($0) } }
        guard known(start.row) else { return nil }
        var top = start.row, bottom = start.row
        while known(top - 1) || known(top - 2) { top -= known(top - 1) ? 1 : 2 }
        while known(bottom + 1) || known(bottom + 2) { bottom += known(bottom + 1) ? 1 : 2 }
        return CGFloat(top) / scale...CGFloat(bottom + 1) / scale
    }
}
