import XCTest

/// What a screenshot shows of a scenario's card: the card, and each of its boxes by name.
struct Reading {
    let pixels: Pixels
    let card: CGRect
    let boxes: [String: (frame: CGRect, pixels: Int)]

    func frame(_ name: String) throws -> CGRect {
        try XCTUnwrap(boxes[name], "the \(name) box shows in the card").frame
    }
}

/// Where the options of a layout put its nodes in the card of the Lock Screen, how high the card is for its content,
/// and what boxes with a background and a corner radius look like. The scenarios (src/placement.rs) draw boxes of
/// pure colors on a card of one color, and each test finds them in a screenshot: lengths of the layout are whole
/// points, a screenshot has two or three pixels to a point, and the two agree to within a pixel.
///
/// No box is black, white or gray, which a wallpaper may be beside the card, and none has the color halfway between
/// the card's and another box's, which the pixels of a rounded edge have. A wallpaper can still have a box's color
/// beside the card's rounded corner (iOS 17's is cyan there): a box is the largest patch of its color in the card.
final class PlacementTests: HostCase {
    /// The card's color in the scenarios, and the boxes at the nine alignments of a frame: where each stands across
    /// and down the card (0 at the leading or top edge, 1 in the middle, 2 at the trailing or bottom edge).
    static let card = RGB(255, 255, 0)
    static let anchors: [(name: String, column: Int, row: Int, color: RGB)] = [
        ("top leading", 0, 0, RGB(255, 0, 0)), ("top", 1, 0, RGB(0, 255, 0)), ("top trailing", 2, 0, RGB(0, 0, 255)),
        ("leading", 0, 1, RGB(255, 0, 255)), ("center", 1, 1, RGB(128, 0, 128)), ("trailing", 2, 1, RGB(0, 255, 255)),
        ("bottom leading", 0, 2, RGB(255, 0, 128)), ("bottom", 1, 2, RGB(128, 0, 255)), ("bottom trailing", 2, 2, RGB(0, 128, 255))
    ]
    /// A pixel of the coarsest screen, and a little: what two lengths may differ by.
    let pixel: CGFloat = 0.55

    /// What the screen shows once it has stopped changing, as pixels, saved as `name`: the first screenshot that is
    /// the same as the one before it. A card that an update made higher grows for a moment, and its texts' frames
    /// say nothing of that.
    func look(as name: String) throws -> Pixels {
        var before: Pixels?
        for _ in 0..<16 {
            let screenshot = XCUIScreen.main.screenshot()
            let now = try XCTUnwrap(Pixels(screenshot, screen: springboard.frame.size), "the screenshot is an image")
            if let before, before.isSame(as: now) {
                try save(screenshot, as: name)
                return now
            }
            before = now
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return try XCTUnwrap(nil as Pixels?, "the screen of \(name) stops changing")
    }

    /// Where the text `title` stands, once it has stopped moving: the Lock Screen may still be coming down. Of
    /// several such texts it is the lowest: the Dynamic Island holds the layout's texts too, at the top of the screen.
    func settled(_ title: String, _ what: String) -> CGRect {
        let texts = springboard.staticTexts.matching(identifier: title)
        var last = CGRect.null
        XCTAssertTrue(waitUntil(10) {
            let now = texts.allElementsBoundByIndex.map(\.frame).max { $0.midY < $1.midY } ?? .null
            defer { last = now }
            return !now.isNull && now == last
        }, "\(what) stands still")
        return last
    }

    /// Runs `scenario`, shows the Lock Screen with its card, known by the text `title`, and reads the screen. The
    /// system's question whether the app may show Live Activities hangs below a card, and comes when it likes, with
    /// the first card or a later one: it is answered when it is there, without a wait for it.
    func shot(_ scenario: String, title: String) throws -> (pixels: Pixels, title: CGRect) {
        launch(scenario)
        waitFor("PASS \(scenario)")
        goHome()
        pullLockScreenDown(until: title)
        var frame = settled(title, "the card of \(scenario)")
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Always Allow", "Allow"])).firstMatch
        if allow.exists {
            allow.tap()
            XCTAssertTrue(waitUntil(10) { !allow.exists }, "the system's question goes once it is answered")
            frame = settled(title, "the card of \(scenario), after the system's question")
        }
        return (try look(as: scenario), frame)
    }

    /// Reads a card of the card's color and its `boxes` from a screenshot. The card is the region of its color that
    /// begins left of the title; a box is the largest patch of its color within the card.
    func read(_ shot: (pixels: Pixels, title: CGRect), _ boxes: [(name: String, color: RGB)] = []) throws -> Reading {
        let from = CGPoint(x: shot.title.minX, y: shot.title.midY)
        let seed = try XCTUnwrap(shot.pixels.nearest(Self.card, leftOf: from),
                                 "the card's color shows left of the title; at the title it is \(String(describing: shot.pixels.color(at: from)))")
        let card = try XCTUnwrap(shot.pixels.region(around: seed), "the card is a region of its color").frame
        let found = shot.pixels.largest(of: boxes.map(\.color), in: card)
        var frames: [String: (frame: CGRect, pixels: Int)] = [:]
        for (box, region) in zip(boxes, found) {
            frames[box.name] = try XCTUnwrap(region, "the \(box.name) box \(box.color) shows in the card \(card)")
        }
        return Reading(pixels: shot.pixels, card: card, boxes: frames)
    }

    func expect(_ frame: CGRect, is width: CGFloat, by height: CGFloat, _ name: String) {
        XCTAssertEqual(frame.width, width, accuracy: pixel, "the width of \(name)")
        XCTAssertEqual(frame.height, height, accuracy: pixel, "the height of \(name)")
    }

    /// The boxes of the scenario's nine alignments: each 44 points, at its edge or in the middle of the card in both
    /// directions. A box in a corner loses what the card's rounding cuts and still reaches both edges, since the
    /// rounding ends within its 44 points.
    func expectAnchors(_ reading: Reading, _ what: String) throws {
        let card = reading.card
        for anchor in Self.anchors {
            let found = try XCTUnwrap(reading.boxes[anchor.name])
            expect(found.frame, is: 44, by: 44, "the \(anchor.name) box \(what)")
            let x = [card.minX, card.midX - 22, card.maxX - 44][anchor.column]
            let y = [card.minY, card.midY - 22, card.maxY - 44][anchor.row]
            XCTAssertEqual(found.frame.minX, x, accuracy: pixel, "the \(anchor.name) box \(what) is at its place across the card \(card)")
            XCTAssertEqual(found.frame.minY, y, accuracy: pixel, "the \(anchor.name) box \(what) is at its place down the card \(card)")
            let shown = CGFloat(found.pixels) / (44 * 44 * reading.pixels.scale * reading.pixels.scale)
            print("placement: \(what): the \(anchor.name) box is at \(found.frame), \(Int((shown * 100).rounded())) % of it shows")
            if anchor.column == 1 || anchor.row == 1 {
                XCTAssertEqual(shown, 1, accuracy: 0.01, "nothing cuts the \(anchor.name) box \(what)")
            }
        }
    }

    // AK-RENDER-18
    /// A frame that fills the card puts its content at each of the nine alignments: at the card's edges, in its
    /// corners and in its middle, to the pixel. The card's own color does not move them: drawn by the widget (a
    /// light and dark pair), as the system's tint (one color) or without one, the boxes are where they were.
    func testAFramesAlignmentsReachTheCardsEdgesAndCorners() throws {
        let boxes = Self.anchors.map { (name: $0.name, color: $0.color) }
        let first = try shot("place-anchors", title: "Anchors")
        let drawn = try read(first, boxes)
        let card = drawn.card, screen = springboard.frame.size
        print("placement: the card is \(card) on a screen of \(screen): \(card.minX) and \(screen.width - card.maxX) points from its sides")
        XCTAssertEqual(card.height, 148, accuracy: pixel, "the card is as high as its content")
        XCTAssertEqual(card.midX, screen.width / 2, accuracy: pixel, "the card is in the middle of the screen")
        try expectAnchors(drawn, "on a drawn card")
        // The card's own corners are rounded: at its very corner another color shows.
        let corner = try XCTUnwrap(drawn.pixels.color(at: CGPoint(x: card.minX + 1, y: card.minY + 1)))
        XCTAssertFalse(corner.isNear(Self.anchors[0].color), "the system rounds the card's corners, and what is in them")

        for (scenario, what) in [("place-anchors-tint", "on a tinted card"), ("place-anchors-plain", "on a card without a color")] {
            let other = try shot(scenario, title: "Anchors")
            print("placement: \(what) the card's color reads \(String(describing: other.pixels.color(at: CGPoint(x: first.title.minX - 3, y: first.title.midY))))")
            // The boxes are looked for in the place of the drawn card: this card's own color is the system's.
            let found = other.pixels.largest(of: Self.anchors.map(\.color), in: card)
            for (anchor, region) in zip(Self.anchors, found) {
                let was = try drawn.frame(anchor.name)
                let now = try XCTUnwrap(region, "the \(anchor.name) box shows \(what)").frame
                for (edge, before, side) in [(now.minX, was.minX, "left"), (now.maxX, was.maxX, "right"),
                                             (now.minY, was.minY, "top"), (now.maxY, was.maxY, "bottom")] {
                    XCTAssertEqual(edge, before, accuracy: pixel, "the \(side) of the \(anchor.name) box \(what) is where it was on a drawn card")
                }
            }
        }
    }

    // AK-RENDER-18
    /// Padding moves what is inside by its points, each edge by its own: a box that fills a card with padding of 10,
    /// 20, 30 and 40 points is that far from the card's top, leading, bottom and trailing edge, and a box inside
    /// padding of 16 points is 16 points from each of its parent's edges.
    func testPaddingInsetsEachEdgeByItsPoints() throws {
        let seen = try read(try shot("place-padding", title: "Padding"), [("outer", RGB(255, 0, 255)), ("inner", RGB(0, 255, 255))])
        let card = seen.card, outer = try seen.frame("outer"), inner = try seen.frame("inner")
        print("placement: padding: the card \(card), the outer box \(outer), the inner box \(inner)")
        XCTAssertEqual(card.height, 140, accuracy: pixel, "the card is as high as its frame says, padding included")
        for (edge, inset, points) in [("top", outer.minY - card.minY, 10), ("leading", outer.minX - card.minX, 20),
                                      ("bottom", card.maxY - outer.maxY, 30), ("trailing", card.maxX - outer.maxX, 40)] {
            XCTAssertEqual(inset, CGFloat(points), accuracy: pixel, "the \(edge) padding of the card")
        }
        for (edge, inset) in [("top", inner.minY - outer.minY), ("leading", inner.minX - outer.minX),
                              ("bottom", outer.maxY - inner.maxY), ("trailing", outer.maxX - inner.maxX)] {
            XCTAssertEqual(inset, 16, accuracy: pixel, "the \(edge) padding of the outer box")
        }
    }

    // AK-RENDER-18, AK-RENDER-19
    /// Stacks and a spacer: a row with a spacer reaches both edges of the card; a column aligns a short bar with a
    /// long one at the leading or the trailing edge, and a row a low box with a high one at the top, the middle or
    /// the bottom. A column without a frame is as wide as its widest bar, and the card shows it in its middle: its
    /// alignment moves the bars in the column, not the column in the card.
    func testStacksAlignAndASpacerReachesBothEdges() throws {
        let boxes: [(name: String, color: RGB, width: CGFloat, height: CGFloat)] = [
            ("edge_leading", RGB(255, 0, 0), 30, 20), ("edge_trailing", RGB(0, 0, 255), 30, 20),
            ("leading_long", RGB(0, 255, 0), 120, 10), ("leading_short", RGB(255, 0, 255), 40, 10),
            ("trailing_long", RGB(0, 255, 255), 120, 10), ("trailing_short", RGB(255, 0, 128), 40, 10),
            ("top_high", RGB(128, 0, 255), 20, 36), ("top_low", RGB(0, 128, 255), 20, 12),
            ("middle_high", RGB(128, 0, 128), 20, 36), ("middle_low", RGB(0, 128, 0), 20, 12),
            ("bottom_high", RGB(0, 128, 128), 20, 36), ("bottom_low", RGB(128, 0, 0), 20, 12),
            ("hug_long", RGB(128, 255, 255), 90, 10), ("hug_short", RGB(255, 128, 192), 30, 10)
        ]
        let seen = try read(try shot("place-stacks", title: "Stacks"), boxes.map { ($0.name, $0.color) })
        for box in boxes { expect(try seen.frame(box.name), is: box.width, by: box.height, "the \(box.name) box") }
        let card = seen.card
        XCTAssertEqual(try seen.frame("edge_leading").minX, card.minX, accuracy: pixel, "the box before the spacer is at the card's leading edge")
        XCTAssertEqual(try seen.frame("edge_trailing").maxX, card.maxX, accuracy: pixel, "the box after the spacer is at the card's trailing edge")
        XCTAssertEqual(try seen.frame("leading_short").minX, try seen.frame("leading_long").minX, accuracy: pixel, "a column aligned leading")
        XCTAssertEqual(try seen.frame("trailing_short").maxX, try seen.frame("trailing_long").maxX, accuracy: pixel, "a column aligned trailing")
        XCTAssertEqual(try seen.frame("top_low").minY, try seen.frame("top_high").minY, accuracy: pixel, "a row aligned at the top")
        XCTAssertEqual(try seen.frame("middle_low").midY, try seen.frame("middle_high").midY, accuracy: pixel, "a row aligned in the middle")
        XCTAssertEqual(try seen.frame("bottom_low").maxY, try seen.frame("bottom_high").maxY, accuracy: pixel, "a row aligned at the bottom")
        XCTAssertEqual(try seen.frame("hug_short").minX, try seen.frame("hug_long").minX, accuracy: pixel, "the bars of a column aligned leading")
        XCTAssertEqual(try seen.frame("hug_long").midX, card.midX, accuracy: pixel, "a column without a frame stands in the middle of the card")
    }

    // AK-RENDER-18
    /// The card is as high as its content, and follows it: one activity shows one to five bars of 40 points, more
    /// and then fewer, by updates. The system gives a card on the Lock Screen at most 160 points: of five bars it
    /// shows the middle 160, with half of the first bar and half of the last cut away.
    func testTheCardGrowsAndShrinksWithItsContent() throws {
        let bars = [RGB(255, 128, 192), RGB(0, 255, 0), RGB(128, 0, 255), RGB(255, 0, 255), RGB(255, 0, 128)]
        // A point in the card: beside the title, or, where the title is cut away with the top of five bars, just
        // above where the card last ended.
        var inside = CGPoint.zero
        for rows in [1, 2, 3, 4, 5, 2] {
            let seen = try shot("size-\(rows)", title: "Rows \(rows)")
            let beside = CGPoint(x: seen.title.minX - 3, y: seen.title.midY)
            if seen.pixels.color(at: beside).map({ color in bars.contains { color.isNear($0) } }) == true { inside = beside }
            let span = try XCTUnwrap(seen.pixels.column(through: inside, of: bars),
                                     "the bars show at \(inside); there it is \(String(describing: seen.pixels.color(at: inside)))")
            inside.y = span.upperBound - 2
            let height = span.upperBound - span.lowerBound
            print("placement: \(rows) bars of 40 points: the card is \(height) points high, from \(span.lowerBound) to \(span.upperBound)")
            if rows <= 4 {
                XCTAssertEqual(height, CGFloat(40 * rows), accuracy: pixel, "the card of \(rows) bars is as high as they are")
                continue
            }
            XCTAssertEqual(height, 160, accuracy: pixel, "the system cuts a card of 200 points at 160")
            let first = try XCTUnwrap(seen.pixels.column(through: CGPoint(x: inside.x, y: span.lowerBound + 1), of: [bars[0]]),
                                      "the first bar is at the card's head")
            let last = try XCTUnwrap(seen.pixels.column(through: CGPoint(x: inside.x, y: span.upperBound - 1), of: [bars[4]]),
                                     "the last bar is at the card's foot")
            XCTAssertEqual(first.upperBound - first.lowerBound, 20, accuracy: pixel, "the first bar's upper half is cut away")
            XCTAssertEqual(last.upperBound - last.lowerBound, 20, accuracy: pixel, "and the last bar's lower half")
        }
    }

    // AK-RENDER-18
    /// A height that is a bound: a card whose frame says at least 120 points is 120 points high around one line of
    /// text. A frame that takes all the height it can get does not get the system's most: how high the system makes
    /// such a card is its own choice, which the test reports.
    func testAFramesBoundsSetTheCardsHeight() throws {
        let least = try read(try shot("place-minimum", title: "At least"))
        XCTAssertEqual(least.card.height, 120, accuracy: pixel, "a minimum height of 120 points")
        let filling = try shot("place-fill", title: "Fills")
        let card = try read(filling).card
        print("placement: a card that takes all the height it can get is \(card)")
        XCTAssertGreaterThanOrEqual(card.height, filling.title.height, "a card that fills holds its line of text")
        XCTAssertLessThanOrEqual(card.height, 160 + pixel, "and is no higher than the system's most")
    }

    // AK-RENDER-18
    /// Boxes that look like cards: a corner radius rounds all four corners of a background, and a radius of half
    /// the height makes a pill; without one the box is a whole rectangle. Padding in a box with a background and a
    /// radius keeps a box inside from each of its edges.
    func testBackgroundsWithACornerRadiusLookLikeCards() throws {
        let magenta = RGB(255, 0, 255), blue = RGB(0, 0, 255), green = RGB(0, 255, 0)
        let seen = try read(try shot("place-shapes", title: "Shapes"),
                            [("round", magenta), ("square", RGB(0, 255, 255)), ("pill", blue), ("outer", green), ("inner", RGB(255, 0, 0))])
        let pixels = seen.pixels
        func color(_ point: CGPoint) throws -> RGB { try XCTUnwrap(pixels.color(at: point)) }
        /// The four points `inset` points in from the corners of `frame`, along both edges.
        func corners(_ frame: CGRect, _ inset: CGFloat) -> [CGPoint] {
            [CGPoint(x: frame.minX + inset, y: frame.minY + inset), CGPoint(x: frame.maxX - inset, y: frame.minY + inset),
             CGPoint(x: frame.minX + inset, y: frame.maxY - inset), CGPoint(x: frame.maxX - inset, y: frame.maxY - inset)]
        }

        let round = try seen.frame("round")
        expect(round, is: 100, by: 48, "the round box")
        for corner in corners(round, 1) { XCTAssertTrue(try color(corner).isNear(Self.card), "a radius of 16 cuts the corner at \(corner)") }
        for corner in corners(round, 8) { XCTAssertTrue(try color(corner).isNear(magenta), "and leaves the box 8 points in, at \(corner)") }

        let cyan = RGB(0, 255, 255), square = try seen.frame("square")
        expect(square, is: 60, by: 48, "the square box")
        for corner in corners(square, 1) { XCTAssertTrue(try color(corner).isNear(cyan), "a box without a radius keeps its corner at \(corner)") }

        let pill = try seen.frame("pill")
        expect(pill, is: 100, by: 40, "the pill")
        for corner in corners(pill, 2) { XCTAssertTrue(try color(corner).isNear(Self.card), "a radius of half the height cuts the corner at \(corner)") }
        for x in [pill.minX + 1, pill.maxX - 1] { XCTAssertTrue(try color(CGPoint(x: x, y: pill.midY)).isNear(blue), "and reaches the pill's end at half its height") }

        let outer = try seen.frame("outer"), inner = try seen.frame("inner")
        expect(outer, is: 300, by: 56, "the outer box")
        expect(inner, is: 284, by: 40, "the box inside its padding of 8 points")
        XCTAssertEqual(inner.midX, outer.midX, accuracy: pixel, "the inner box is in the middle of the outer one, across")
        XCTAssertEqual(inner.midY, outer.midY, accuracy: pixel, "and down")
        for corner in corners(outer, 1) { XCTAssertTrue(try color(corner).isNear(Self.card), "the outer box's corner is cut at \(corner)") }
        for corner in corners(inner, 0.5) { XCTAssertTrue(try color(corner).isNear(green), "the inner box's corner is cut at \(corner)") }
        print("placement: shapes: the card \(seen.card); round \(round), pill \(pill), outer \(outer), inner \(inner)")
    }

    // AK-ISLAND-3
    /// The expanded Dynamic Island draws its trailing value whole: as many of its pixels as the same value has in the
    /// bottom region, where it has room. The top corner of the expanded content area cut its last letter before (91 %
    /// showed on the iOS 26.3 simulator; margins around the expanded island made it worse, 80 %, and 6 points of
    /// padding on the value made it whole). The island is expanded by a long press on its compact form.
    func testTheExpandedIslandKeepsItsTrailingValueWhole() throws {
        if showsBanners { throw XCTSkip("a phone without a Dynamic Island") }
        launch("place-island")
        waitFor("PASS place-island")
        goHome()
        // The compact island shows the value once the system has drawn the activity, which takes a while on a new
        // simulator.
        let compact = springboard.staticTexts["9 min"].firstMatch
        let drawn = compact.waitForExistence(timeout: 120)
        if !drawn { try? capture("island-compact-missing") }
        XCTAssertTrue(drawn, "the compact island shows the value")
        // A long press does not always take on a busy simulator: up to three.
        let title = springboard.staticTexts["Island title"].firstMatch
        for _ in 1...3 {
            compact.press(forDuration: 1.5)
            if title.waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(title.exists, "a long press expands the island")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let pixels = try look(as: "island-expanded")
        let top = CGRect(x: 0, y: 0, width: springboard.frame.width, height: 200)
        let value = try XCTUnwrap(pixels.span(of: RGB(0, 255, 0), in: top), "the trailing value shows")
        let whole = pixels.count(of: RGB(0, 255, 255), in: top)
        XCTAssertGreaterThan(whole, 100, "the same value shows whole in the bottom region, the measure")
        let shown = Double(pixels.count(of: RGB(0, 255, 0), in: top)) / Double(max(1, whole))
        print("placement: island: the value \(value), \(Int((shown * 100).rounded())) % of the pixels it has whole")
        XCTAssertGreaterThanOrEqual(shown, 0.98, "the trailing value is whole")
        XCUIDevice.shared.press(.home)
    }

    /// Whether the simulated phone has no Dynamic Island: such a phone shows an alert as a banner. By its model:
    /// every iPhone up to the 14 (`iPhone14,8`) and the 16e (`iPhone17,5`); the 14 Pro (`iPhone15,2`) began the island.
    var showsBanners: Bool {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        let major = Int(model.dropFirst("iPhone".count).prefix { $0.isNumber }) ?? Int.max
        return model.hasPrefix("iPhone") && (major <= 14 || model == "iPhone17,5")
    }

    // AK-RENDER-18
    /// On a phone without a Dynamic Island an alert shows the Lock Screen presentation as a banner over the Home
    /// Screen: the same card, with its boxes at the same places in it.
    func testAnAlertShowsTheCardAsABanner() throws {
        if !showsBanners { throw XCTSkip("a phone with a Dynamic Island shows an alert in the island: run with DEVICE_TYPE of one without") }
        launch("place-banner")
        waitFor("started")
        goHome()
        XCTAssertTrue(springboard.staticTexts["Anchors"].firstMatch.waitForExistence(timeout: 30), "the alert shows the card over the Home Screen")
        let frame = settled("Anchors", "the banner")
        let banner = try read((try look(as: "place-banner"), frame), Self.anchors.map { ($0.name, $0.color) })
        print("placement: the banner is \(banner.card) on a screen of \(springboard.frame.size)")
        XCTAssertEqual(banner.card.height, 148, accuracy: pixel, "the banner is as high as its content")
        try expectAnchors(banner, "in a banner")
    }
}
