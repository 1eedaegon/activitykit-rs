import XCTest

/// ActivityKit's handling of dismissals and relevance, read through the crate. The scenario leaves ended activities on
/// the Lock Screen, so this class runs after `HostTests` (XCTest runs classes by name).
final class PolicyTests: HostCase {
    // AK-BRIDGE-9, AK-END-2, AK-END-3, AK-END-6, AK-UPDATE-12
    func testDismissalsAndRelevance() throws {
        launch("policies")
        waitFor("PASS policies", timeout: 180)
        try capture("policies-report")
    }
}
