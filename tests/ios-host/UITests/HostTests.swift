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

    /// Pulls the Lock Screen down over the Home Screen, and allows Live Activities if the system asks.
    func showLockScreen(until text: String) {
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        XCTAssertTrue(springboard.staticTexts[text].waitForExistence(timeout: 15), "\(text) shows on the Lock Screen")
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
