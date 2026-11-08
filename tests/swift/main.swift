import Foundation

@main
struct LifecycleTests {
    static var assertions = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(label)") }
    }
    @MainActor static func expectError(_ code: String, _ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Expected \(code)") }
        catch let error as ActivityFailure { expect(error.code == code, "error code \(code), got \(error.code)") }
        catch { fatalError("Unexpected error \(error)") }
    }
    @MainActor static func main() async throws {
        testPlatformSupport()
        try testLayoutFixtures()
        try await testLayoutModels()
        try testLayoutRender()
        try testLayoutCustomizations()
        try await testLayoutLifecycle()
        try await testReceipts()
        try await testActivityKitMapping()
        try await testBridge()
        print("Swift tests: \(assertions) assertions passed")
    }
}
