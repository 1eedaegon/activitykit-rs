import XCTest

/// The end-to-end check of the example: the app (launched with `-auto`) starts an activity and turns its status red;
/// the test reads it on the Lock Screen, taps its Stop button there, and waits for the app to log that the tap reached
/// Rust and the activity ended. Screenshots go to the folder in `AK_SHOTS`, else to the runner's Documents.
final class LockScreenTests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.activitykit.example")
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func status(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", "Status: \(text)")).firstMatch
    }

    private func capture(_ name: String) throws {
        let folder = ProcessInfo.processInfo.environment["AK_SHOTS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent(name + ".png"), options: .atomic)
    }

    private func allowLiveActivities() {
        for label in ["Always Allow", "Allow"] {
            let control = springboard.buttons[label].firstMatch
            if control.exists { control.tap() }
        }
    }

    func testLockScreenButtonReachesRust() throws {
        app.terminate()
        app.launchArguments = ["-auto"]
        app.launch()
        XCTAssertTrue(status("updated").waitForExistence(timeout: 60), "the app started and updated its activity")
        try capture("1-app-updated")

        // Leave the app, as someone does before locking the phone.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)

        // Pull the Lock Screen down over the Home Screen.
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.01))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)))
        XCTAssertTrue(springboard.staticTexts["Too loud"].waitForExistence(timeout: 15), "the updated status shows on the Lock Screen")
        allowLiveActivities()
        let stop = springboard.buttons["Stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 10), "the Stop button shows on the Lock Screen")
        Thread.sleep(forTimeInterval: 1)
        try capture("2-lock-screen")
        stop.tap()

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        XCTAssertTrue(status("ended").waitForExistence(timeout: 30), "the tap reached Rust, which ended the activity")
        let action = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "action stop from")).firstMatch
        XCTAssertTrue(action.exists, "the app logged the action event")
        try capture("3-app-log")
    }
}
