import Foundation

extension LifecycleTests {
    /// `ak_configure` with `json`, which must reply before it returns.
    @MainActor static func configure(_ json: String) -> [String: Any] {
        let box = ReplyBox()
        Data(json.utf8).withUnsafeBytes {
            C.configure($0.bindMemory(to: UInt8.self).baseAddress, $0.count, Unmanaged.passRetained(box).toOpaque(), replyToBox)
        }
        expect(box.count == 1, "ak_configure replies before it returns")
        return object(box.data)
    }

    // AK-BRIDGE-10, AK-KIT-3, AK-LIST-4
    /// The settings hold for the process: the first ones, or the default ones that the lifecycle's first use fixes.
    /// Redacted receipts keep no values.
    @MainActor static func testSettings() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let system = install()
        system.receipts = folder.appendingPathComponent("redacted.json")
        let set = configure(#"{"receipts":"redacted"}"#)
        expect(set["ok"] as? Bool == true && data(set) as NSDictionary == ["receipts": "redacted"], "the first settings hold")
        expect(data(configure(#"{"receipts":"redacted"}"#)) as NSDictionary == ["receipts": "redacted"], "the same settings again are fine")
        expect(code(configure(#"{"receipts":"full"}"#)) == "CONFLICT", "other settings conflict")
        for bad in ["{}", #"{"receipts":"hashed"}"#, #"{"receipts":"full","more":1}"#, #"{"receipts":null}"#, "not json"] {
            expect(code(configure(bad)) == "INVALID_INPUT", "settings are read strictly: \(bad)")
        }
        let secret = layoutJSON(key: "secret", lockScreen: #"{"type":"text","bind":"title"}"#, values: #"{"title":"Whispered words"}"#)
        let started = await call(C.start, #"{"request":\#(secret)}"#)
        expect(started["ok"] as? Bool == true && system.mode == .redacted, "the lifecycle runs with the configured receipts")
        let text = try fileText(folder.appendingPathComponent("redacted.json"))
        expect(!text.contains("Whispered") && text.contains("digest"), "a redacted receipt keeps a digest, not the values")
        expect(code(configure(#"{"receipts":"full"}"#)) == "CONFLICT", "the settings hold while the lifecycle runs")

        // Without settings, the first use fixes the default ones.
        let plain = install()
        plain.receipts = folder.appendingPathComponent("full.json")
        _ = await call(C.start, #"{"request":\#(secret)}"#)
        let full = try fileText(folder.appendingPathComponent("full.json"))
        expect(plain.mode == .full && full.contains("Whispered"), "without settings receipts are full")
        expect(code(configure(#"{"receipts":"redacted"}"#)) == "CONFLICT", "after the first use other settings conflict")
        expect(data(configure(#"{"receipts":"full"}"#)) as NSDictionary == ["receipts": "full"], "the settings in force are fine")
    }
}
