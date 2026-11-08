import XCTest

/// Drives the Rust scenarios of the host app on a simulator. The app shows the last line a scenario reported under
/// the identifier `status`. Screenshots go to the folder in `AK_SHOTS` (run.sh sets it), else to the runner's Documents.
final class HostTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.activitykit.host")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    override func setUp() {
        continueAfterFailure = false
    }

    private var status: XCUIElement { app.staticTexts["status"] }

    /// Waits until the status starts with `prefix`; a FAIL line of the scenario fails the test at once.
    private func waitFor(_ prefix: String, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if status.exists {
                let label = status.label
                if label.hasPrefix(prefix) { return }
                if label.hasPrefix("FAIL") { XCTFail(label); return }
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("waited \(Int(timeout)) s for \(prefix); the status is \(status.exists ? status.label : "missing")")
    }

    private func launch(_ scenario: String) {
        app.terminate()
        app.launchArguments = ["-scenario", scenario]
        app.launch()
    }

    private func capture(_ name: String) throws {
        let folder = ProcessInfo.processInfo.environment["AK_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
    }

    /// Start, the bound color turned red, Stop tapped on the Lock Screen, the tap's event in Rust, end.
    // AK-CUSTOM-3, AK-EVENT-1, AK-EVENT-2, AK-EVENT-6, AK-EVENT-8, AK-KIT-1, AK-RENDER-3, AK-RENDER-10, AK-UPDATE-5, AK-WIDGET-1
    func testLockScreenButtonReachesRust() throws {
        launch("lockscreen")
        waitFor("updated")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        // Pull the Lock Screen down over the Home Screen.
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        XCTAssertTrue(springboard.staticTexts["Too loud"].waitForExistence(timeout: 15), "the updated status shows on the Lock Screen")
        // The system asks once whether the app may show Live Activities.
        for label in ["Always Allow", "Allow"] where springboard.buttons[label].firstMatch.exists {
            springboard.buttons[label].firstMatch.tap()
        }
        let stop = springboard.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the Stop button shows on the Lock Screen")
        Thread.sleep(forTimeInterval: 1)
        try capture("lock-screen")
        stop.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        waitFor("PASS lockscreen", timeout: 60)
        try capture("lockscreen-report")
    }

    // AK-RENDER-16, AK-WIDGET-1
    /// A layout with every node type draws on the Lock Screen, and its button reaches Rust.
    func testEveryNodeTypeDraws() throws {
        launch("every-node")
        waitFor("shown")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 1)
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        XCTAssertTrue(springboard.staticTexts["Every node"].waitForExistence(timeout: 15), "the layout shows on the Lock Screen")
        for label in ["Always Allow", "Allow"] where springboard.buttons[label].firstMatch.exists {
            springboard.buttons[label].firstMatch.tap()
        }
        let tap = springboard.buttons["Tap"].firstMatch
        XCTAssertTrue(tap.waitForExistence(timeout: 10), "its button shows")
        Thread.sleep(forTimeInterval: 1)
        try capture("every-node")
        tap.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitFor("PASS every-node", timeout: 60)
    }

    // AK-START-10
    /// A start from the background reaches ActivityKit, which refuses it; the crate reports NotForeground.
    func testBackgroundStartIsNotForeground() throws {
        launch("background-start")
        waitFor("waiting")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 9)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        waitFor("PASS background-start", timeout: 30)
    }

    /// After the process ends, `activities()` finds the activity at its accepted revision, and its handle continues.
    // AK-HANDLE-1, AK-LIST-1
    func testActivitiesAfterRelaunch() throws {
        launch("relaunch-start")
        waitFor("PASS relaunch-start")
        app.terminate()
        launch("relaunch-check")
        waitFor("PASS relaunch-check")
        try capture("relaunch-report")
    }
}
