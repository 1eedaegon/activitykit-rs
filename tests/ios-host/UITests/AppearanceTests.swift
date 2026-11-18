import XCTest

/// Which color of a light and dark pair a part of a screenshot shows.
enum PairColor: Equatable, CustomStringConvertible {
    case light, dark
    /// Neither color of the pair: the average of the part, for the failure's text.
    case neither(red: Int, green: Int, blue: Int)

    var description: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        case let .neither(red, green, blue): return "neither (\(red), \(green), \(blue))"
        }
    }
}

/// A screenshot as its pixels, read by parts given in the points of the screen.
struct Pixels {
    private let bytes: [UInt8]
    private let width: Int
    private let height: Int
    private let scale: CGFloat

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
}

/// The colors of light and dark pairs on the Lock Screen, where the system draws the widget's view and not the app:
/// the scenario `appearance` colors its card yellow or blue and a box in it green or magenta.
final class AppearanceTests: HostCase {
    override func tearDown() {
        XCUIDevice.shared.appearance = .light
        super.tearDown()
    }

    /// What the Lock Screen shows of the two pairs: of the card's left of the box, near the card's edge, where
    /// nothing but the card's background is, and of the box's beside the word in it.
    func pairs(_ name: String) throws -> (card: PairColor, box: PairColor) {
        let screenshot = XCUIScreen.main.screenshot()
        try save(screenshot, as: name)
        let pixels = try XCTUnwrap(Pixels(screenshot, screen: springboard.frame.size), "the screenshot is an image")
        // The box is 220 points wide around the word, in the middle of the card.
        let word = springboard.staticTexts["Box"].frame
        let card = pixels.color(in: CGRect(x: word.midX - 150, y: word.minY, width: 16, height: word.height),
                                light: (255, 255, 0), dark: (0, 0, 255))
        let box = pixels.color(in: CGRect(x: word.maxX + 12, y: word.minY, width: 40, height: word.height),
                               light: (0, 255, 0), dark: (255, 0, 255))
        print("\(name): the card is \(card), the box is \(box)")
        return (card, box)
    }

    /// The card and the box show colors of the same appearance.
    func expectOneAppearance(_ name: String, _ what: String) throws {
        let seen = try pairs(name)
        XCTAssertTrue(seen.card == .light || seen.card == .dark, "the card of \(what) is \(seen.card)")
        XCTAssertEqual(seen.card, seen.box, "the card and the box of \(what)")
    }

    // AK-RENDER-17
    /// New activities in the light appearance, where a card came with the light color behind content of the dark
    /// appearance and stayed so, and one in the dark: the card and the box agree as soon as the test sees them and
    /// after the system's question. They still do when the appearance turns under the activity, with the app ended.
    /// Which appearance the Lock Screen draws an activity in is the system's, and the test reports it.
    func testAColorPairIsOfOneAppearance() throws {
        let starts: [(XCUIDevice.Appearance, String)] = [(.light, "light-1"), (.light, "light-2"), (.light, "light-3"), (.dark, "dark")]
        for (appearance, name) in starts {
            XCUIDevice.shared.appearance = appearance
            launch("appearance")
            waitFor("PASS appearance")
            goHome()
            pullLockScreenDown(until: "Appearance")
            try expectOneAppearance("appearance-\(name)-new", "a new activity (\(name))")
            allowLiveActivities()
            try expectOneAppearance("appearance-\(name)-settled", "an activity that is drawn (\(name))")
            XCUIDevice.shared.press(.home)
        }

        app.terminate()
        XCUIDevice.shared.appearance = .light
        pullLockScreenDown(until: "Appearance")
        for look in 1...3 {
            try expectOneAppearance("appearance-turned-\(look)", "an activity whose appearance turned light (look \(look))")
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
    }
}
