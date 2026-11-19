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
