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

    /// The pixels of the color at `seed` that hang together with it, side by side or one above the other: the part
    /// of the screen they span, and how many they are. A card of one color is such a region, whatever lies on it.
    func region(around seed: CGPoint) -> (frame: CGRect, pixels: Int)? {
        guard let wanted = color(at: seed) else { return nil }
        let screen = CGRect(x: 0, y: 0, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        return regions(around: seed, of: [wanted], in: screen)[0]
    }

    /// What hangs together with the pixel at `seed` through pixels of `colors`, side by side or one above the other,
    /// and inside `part`: for each color, in their order, the part of the screen its pixels span and how many they
    /// are, or nil without one. A box on a card of one of the colors is found so, and a pixel of the same color
    /// elsewhere is not, such as the wallpaper beside a card's rounded corner: the mixed pixels of the corner's edge
    /// lie between.
    func regions(around seed: CGPoint, of colors: [RGB], in part: CGRect) -> [(frame: CGRect, pixels: Int)?] {
        let left = max(0, Int((part.minX * scale).rounded())), right = min(width, Int((part.maxX * scale).rounded()))
        let top = max(0, Int((part.minY * scale).rounded())), bottom = min(height, Int((part.maxY * scale).rounded()))
        var spans = [(columns: ClosedRange<Int>, rows: ClosedRange<Int>, count: Int)?](repeating: nil, count: colors.count)
        guard let start = pixel(seed), left < right, top < bottom else { return spans.map { _ in nil } }
        // Which of the colors a pixel has: read once for each pixel. -2 is not read yet, -1 none of them.
        var kinds = [Int8](repeating: -2, count: (right - left) * (bottom - top))
        func kind(_ column: Int, _ row: Int) -> Int {
            guard column >= left, column < right, row >= top, row < bottom else { return -1 }
            let at = (row - top) * (right - left) + (column - left)
            if kinds[at] == -2 {
                let seen = color(column, row)
                kinds[at] = Int8(colors.firstIndex { seen.isNear($0) } ?? -1)
            }
            return Int(kinds[at])
        }
        var visited = [Bool](repeating: false, count: kinds.count)
        var open: [(Int, Int)] = []
        func visit(_ column: Int, _ row: Int) {
            guard kind(column, row) >= 0 else { return }
            let at = (row - top) * (right - left) + (column - left)
            if !visited[at] {
                visited[at] = true
                open.append((column, row))
            }
        }
        visit(start.column, start.row)
        while let (column, row) = open.popLast() {
            let index = kind(column, row)
            if let span = spans[index] {
                spans[index] = (min(span.columns.lowerBound, column)...max(span.columns.upperBound, column),
                                min(span.rows.lowerBound, row)...max(span.rows.upperBound, row), span.count + 1)
            } else {
                spans[index] = (column...column, row...row, 1)
            }
            visit(column + 1, row)
            visit(column - 1, row)
            visit(column, row + 1)
            visit(column, row - 1)
        }
        return spans.map { span in span.map { (frame($0.columns, $0.rows), $0.count) } }
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
