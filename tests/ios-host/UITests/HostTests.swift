import XCTest

/// Whether the host app said that its scenario is over, by a Darwin notification, which reaches the test also while the
/// app is in the background.
final class Finished: @unchecked Sendable {
    static let shared = Finished()
    static let name = "dev.activitykit.host.finished" as CFString
    private let lock = NSLock()
    private var heard = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return heard }
        set { lock.lock(); heard = newValue; lock.unlock() }
    }
}

/// Drives the Rust scenarios of the host app on a simulator. The app shows the last line a scenario reported under
/// the identifier `status`. Screenshots go to the folder in `AK_SHOTS` (run.sh sets it), else to the runner's Documents.
class HostCase: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "dev.activitykit.host")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
    }

    var status: XCUIElement { app.staticTexts["status"] }

    /// Waits until `condition` holds, checking every 0.25 s; false after `timeout`.
    @discardableResult
    func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Waits until the status starts with `prefix`; a FAIL line of the scenario fails the test at once.
    func waitFor(_ prefix: String, timeout: TimeInterval = 60) {
        var failed: String?
        let found = waitUntil(timeout) {
            guard status.exists else { return false }
            let label = status.label
            if label.hasPrefix("FAIL") { failed = label; return true }
            return label.hasPrefix(prefix)
        }
        if let failed { XCTFail(failed); return }
        if !found { XCTFail("waited \(Int(timeout)) s for \(prefix); the status is \(status.exists ? status.label : "missing")") }
    }

    func launch(_ scenario: String) {
        app.terminate()
        app.launchArguments = ["-scenario", scenario]
        app.launch()
    }

    /// Starts listening for the app's notice that its scenario is over.
    func listenForTheEnd() {
        Finished.shared.value = false
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(Finished.shared).toOpaque(),
                                        { _, _, _, _, _ in Finished.shared.value = true }, Finished.name, nil, .deliverImmediately)
    }

    /// Whether the app said its scenario is over, within `timeout`. The notice arrives on this thread's run loop.
    func heardTheEnd(timeout: TimeInterval) -> Bool {
        defer {
            CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(Finished.shared).toOpaque(),
                                               CFNotificationName(Finished.name), nil)
        }
        return waitUntil(timeout) { Finished.shared.value }
    }

    /// Home, once the app has left the foreground.
    func goHome() {
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(waitUntil(10) { app.state != .runningForeground }, "the app leaves the foreground")
    }

    /// Pulls the Lock Screen down over the Home Screen.
    func pullLockScreenDown() {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
    }

    /// Pulls the Lock Screen down until `text` shows, and allows Live Activities if the system asks.
    func showLockScreen(until text: String) {
        pullLockScreenDown()
        // A new simulator can take half a minute to draw its first activity.
        let shown = springboard.staticTexts[text].waitForExistence(timeout: 45)
        if !shown {
            // What the Lock Screen holds instead, for the log and the screenshots.
            try? capture("lock-screen-without-" + text.replacingOccurrences(of: " ", with: "-"))
            print("the Lock Screen without \(text):\n\(springboard.debugDescription)")
        }
        XCTAssertTrue(shown, "\(text) shows on the Lock Screen")
        // The system asks once whether the app may show Live Activities.
        let allow = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Always Allow", "Allow"])).firstMatch
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    func capture(_ name: String) throws {
        let folder = ProcessInfo.processInfo.environment["AK_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
    }
}

final class HostTests: HostCase {
    /// Start, the bound color turned red, content older than the shown one dropped, Stop tapped on the Lock Screen,
    /// the tap's event in Rust, end.
    // AK-CUSTOM-3, AK-EVENT-1, AK-EVENT-2, AK-EVENT-6, AK-EVENT-8, AK-EVENT-14, AK-KIT-1, AK-RENDER-3, AK-RENDER-10, AK-UPDATE-5, AK-UPDATE-16, AK-WIDGET-1
    func testLockScreenButtonReachesRust() throws {
        launch("lockscreen")
        waitFor("updated")
        goHome()
        showLockScreen(until: "Too loud")
        // Rendering may lag behind: the older content must not show within 2 s either, and the newer one stays.
        XCTAssertFalse(springboard.staticTexts["Old news"].waitForExistence(timeout: 2), "ActivityKit drops content older than the shown one")
        XCTAssertTrue(springboard.staticTexts["Too loud"].exists, "the newer content still shows")
        let stop = springboard.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the Stop button shows on the Lock Screen")
        XCTAssertTrue(waitUntil(5) { stop.isHittable }, "the Stop button can be tapped")
        try capture("lock-screen")
        stop.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        waitFor("PASS lockscreen", timeout: 60)
        try capture("lockscreen-report")
    }

    // AK-ACCESS-3, AK-LINK-5
    /// What the widget tells assistive technologies is on the Lock Screen, a touch still reaches a button inside a
    /// labelled stack, and a tap on a link, or beside it, opens the app with the URL, also one whose scheme is not
    /// the app's: the system hands every URL to the app that owns the activity.
    func testLabelsAndLinksOnTheLockScreen() throws {
        launch("surface")
        waitFor("shown")
        goHome()
        showLockScreen(until: "Surface")
        func labelled(_ label: String) -> XCUIElement {
            springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        // The system reads the activity's elements from the widget's process, which can take a while after it drew.
        let trend = labelled("Trend line").waitForExistence(timeout: 30)
        if !trend {
            try? capture("surface-without-labels")
            print("the Lock Screen without the path's label:\n\(springboard.debugDescription)")
        }
        XCTAssertTrue(trend, "a path is read by its label")
        let level = labelled("Input level")
        XCTAssertTrue(level.waitForExistence(timeout: 10), "a progress view is read by its label")
        XCTAssertEqual(level.value as? String, "40 percent", "and by the value its accessibility binds")
        let row = labelled("Level row")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "a stack with a label is an element of its own")
        // The element took the trait of the button it holds: it stands for its children. (The tree a UI test sees
        // lists what is inside an element too, as it lists the text inside a button.)
        XCTAssertEqual(row.elementType, .button, "that stands for the button inside it")
        // A hidden node is not checked: a UI test lists hidden elements too, in an app as in an activity.
        try capture("surface")
        // The button stands at the trailing end of the labelled stack: a touch there still reaches it.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        waitFor("PASS surface", timeout: 60)
        let taps = [("Open details", "activitykit-host://opened?from=link"), ("Surface", "activitykit-host://opened?from=activity"),
                    ("Open web", "https://example.com/activitykit")]
        for (label, url) in taps {
            goHome()
            showLockScreen(until: "Surface")
            let target = labelled(label)
            XCTAssertTrue(target.waitForExistence(timeout: 10), "\(label) shows on the Lock Screen")
            target.tap()
            XCTAssertTrue(app.staticTexts["URL \(url)"].waitForExistence(timeout: 20), "a tap on \(label) opens the app with \(url)")
        }
        try capture("surface-report")
    }

    // AK-RENDER-16, AK-WIDGET-1
    /// A layout with every node type draws on the Lock Screen, and its button reaches Rust.
    func testEveryNodeTypeDraws() throws {
        launch("every-node")
        waitFor("shown")
        goHome()
        showLockScreen(until: "Every node")
        let tap = springboard.buttons["Tap"].firstMatch
        XCTAssertTrue(tap.waitForExistence(timeout: 10), "its button shows")
        XCTAssertTrue(waitUntil(5) { tap.isHittable }, "its button can be tapped")
        try capture("every-node")
        tap.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitFor("PASS every-node", timeout: 60)
    }

    // AK-START-10, AK-START-11
    /// A start from the background reaches ActivityKit, which refuses it; the crate reports NotForeground. The app says
    /// by a Darwin notification when the scenario is over.
    func testBackgroundStartIsNotForeground() throws {
        launch("background-start")
        waitFor("waiting")
        listenForTheEnd()
        goHome()
        XCTAssertTrue(heardTheEnd(timeout: 60), "the scenario finishes in the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitFor("PASS background-start", timeout: 30)
    }

    // AK-START-14
    /// A scheduled start is pending until its time, holds its key and takes no update, and is then active and on the
    /// Lock Screen with the content of its start.
    func testScheduledStart() throws {
        launch("scheduled-start")
        waitFor("PASS scheduled-start", timeout: 150)
        goHome()
        showLockScreen(until: "Soon")
        try capture("scheduled-start")
    }

    // AK-START-13, AK-ALERT-1
    /// ActivityKit takes an alert with a named sound and a transient start. The scenario reports what the system did
    /// with that activity after the app left the foreground.
    func testStartOptions() throws {
        launch("start-options")
        waitFor("transient", timeout: 120)
        listenForTheEnd()
        goHome()
        XCTAssertTrue(heardTheEnd(timeout: 60), "the scenario finishes in the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitFor("PASS start-options", timeout: 30)
        try capture("start-options-report")
    }

    // AK-TOGGLE-1
    /// A toggle on the Lock Screen shows its flag; a tap reaches Rust with the state asked for, and the app's update
    /// moves the switch.
    func testToggleAsksForTheOtherState() throws {
        launch("toggle")
        waitFor("shown")
        goHome()
        showLockScreen(until: "Toggles")
        let toggle = springboard.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Mute")).firstMatch
        let shown = toggle.waitForExistence(timeout: 30)
        if !shown {
            try? capture("toggle-missing")
            print("the Lock Screen without the toggle:\n\(springboard.debugDescription)")
        }
        XCTAssertTrue(shown, "the toggle shows on the Lock Screen")
        XCTAssertEqual(toggle.elementType, .switch, "as a switch")
        XCTAssertEqual(toggle.value as? String, "0", "that is off, like its flag")
        try capture("toggle-off")
        toggle.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        waitFor("muted true", timeout: 60)
        goHome()
        showLockScreen(until: "Toggles")
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "the toggle is still there")
        XCTAssertTrue(waitUntil(15) { toggle.value as? String == "1" }, "and on, once the app set the flag")
        try capture("toggle-on")
        toggle.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        waitFor("PASS toggle", timeout: 60)
    }

    // AK-KIT-3, AK-LIST-4
    /// With redacted receipts the file keeps no values; after a relaunch the list gives the values ActivityKit shows.
    func testRedactedReceiptsAfterRelaunch() throws {
        launch("redacted-start")
        waitFor("PASS redacted-start")
        app.terminate()
        launch("redacted-check")
        waitFor("PASS redacted-check")
        try capture("redacted-report")
    }

    // AK-PUSH-1, AK-PUSH-6
    /// In the simulator, which has no APNs, a start that asks for a push token fails after the call wait and leaves
    /// nothing; the app's own update of a plain activity does not come back as `Event::Updated`.
    func testAStartWithAPushTokenNeedsAPNs() throws {
        launch("push-start")
        waitFor("PASS push-start", timeout: 60)
        try capture("push-start")
    }

    // AK-EVENT-15
    /// A tap on the Lock Screen while the app is not running launches it in the background; the tap reaches Rust,
    /// whose handler updates the activity, and the intent is acknowledged after the handler.
    func testATapLaunchesTheApp() throws {
        launch("cold-tap-start")
        waitFor("PASS cold-tap-start")
        // The widget draws the activity in its own process: give it a moment before the app dies.
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        app.terminate()
        XCTAssertTrue(waitUntil(10) { app.state == .notRunning }, "the app is killed")
        listenForTheEnd()
        showLockScreen(until: "Waiting")
        let stop = springboard.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the Stop button shows on the Lock Screen")
        XCTAssertTrue(waitUntil(5) { stop.isHittable }, "the Stop button can be tapped")
        stop.tap()
        XCTAssertTrue(springboard.staticTexts["Launched"].waitForExistence(timeout: 30), "the launched app's handler updated the activity")
        try capture("cold-tap")
        XCTAssertTrue(heardTheEnd(timeout: 30), "the scenario finishes in the background")
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitFor("PASS cold-tap", timeout: 30)
    }

    /// After the process ends, `activities()` finds the activity at its accepted revision, and its handle continues.
    // AK-HANDLE-1, AK-LIST-1, AK-START-3
    func testActivitiesAfterRelaunch() throws {
        launch("relaunch-start")
        waitFor("PASS relaunch-start")
        app.terminate()
        launch("relaunch-check")
        waitFor("PASS relaunch-check")
        try capture("relaunch-report")
    }
}
