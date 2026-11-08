import CryptoKit
import Foundation

extension LifecycleTests {
    static func receiptFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static func fileText(_ url: URL) throws -> String { String(decoding: try Data(contentsOf: url), as: UTF8.self) }
    static func fileEntries(_ url: URL) throws -> [[String: Any]] {
        guard let entries = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]] else { fatalError("FAIL: receipts are an array") }
        return entries
    }
    static func digest<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    static func transcript(_ revision: Int64, _ text: String) -> LayoutSnapshot { LayoutSnapshot(revision: revision, values: ["transcript": .string(text)]) }
    static func transcriptRequest(_ text: String) throws -> LayoutRequest {
        try layoutRequest(layoutJSON(key: "private", lockScreen: #"{"type":"text","bind":"transcript"}"#, values: #"{"transcript":"\#(text)"}"#))
    }
    static let entryKeys: Set<String> = ["id", "activityKey", "schemaVersion", "state", "revision", "fingerprint", "content"]

    @MainActor static func testReceipts() async throws {
        try await testFullLayoutReceipts()
        try await testRedactedLayoutReceipts()
        try await testRedactedEndAfterRestart()
        try await testGuessableRedaction()
        try await testReceiptFileRules()
    }

    /// The limit `ReceiptMode` documents: a redacted file holds no text, but a snapshot made only of guessable values is
    /// recovered by hashing candidates.
    @MainActor private static func testGuessableRedaction() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let controller = LayoutActivityController(backend: FakeLayoutBackend(), store: FileReceiptStore(url: url, mode: .redacted))
        _ = try await controller.start(layoutRequest(layoutJSON(key: "answer", lockScreen: #"{"type":"text","bind":"answer"}"#,
                                                                values: #"{"answer":"Maybe"}"#)))
        let stored = (try fileEntries(url)[0]["content"] as? [String: Any])?["digest"] as? String
        let guessed = try ["Yes", "No", "Maybe"].first { try digest(LayoutSnapshot(revision: 0, values: ["answer": .string($0)])) == stored }
        try await verify(!(try fileText(url)).contains("Maybe") && guessed == "Maybe",
                         "a redacted file holds no snapshot text, yet a guessable snapshot is recovered from its digest")
    }

    // AK-END-5
    /// After a restart a redacted receipt knows the accepted revision only by its digest. While ActivityKit still
    /// shows an older revision, end must not publish that one again, and the tombstone keeps the accepted revision.
    @MainActor private static func testRedactedEndAfterRestart() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let lagging = FakeLayoutBackend()
        lagging.delayObservation = true
        let first = LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted))
        let saved = try await first.start(transcriptRequest("Recording"))
        _ = try await first.update(layoutUpdate(saved.id, transcript(1, "Saved")))
        let other = layoutJSON(key: "other", lockScreen: #"{"type":"text","bind":"transcript"}"#, values: #"{"transcript":"Current"}"#)
        let current = try await first.start(layoutRequest(other))
        _ = try await first.update(layoutUpdate(current.id, transcript(1, "Kept in memory")))
        _ = try await first.end(layoutEnd(current.id))
        expect(lagging.ends == ["end 1"], "within one process a redacted end publishes the accepted snapshot")

        let restart = LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted))
        let ended = try await restart.end(layoutEnd(saved.id))
        expect(lagging.ends == ["end 1", "keep"], "after a restart a lagging redacted end publishes no older snapshot")
        expect(ended.state == "ended" && ended.snapshot == transcript(0, "Recording"), "the end record reports what the system shows")
        let tombstone = try fileEntries(url).first { $0["id"] as? String == saved.id } ?? [:]
        try await verify(tombstone["state"] as? String == "ended" && tombstone["revision"] as? Int == 1
            && NSDictionary(dictionary: tombstone["content"] as? [String: Any] ?? [:]).isEqual(to: ["digest": try digest(transcript(1, "Saved"))]),
               "the redacted tombstone keeps the accepted revision and its digest")
        let repeated = try await LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted)).end(layoutEnd(saved.id))
        expect(repeated.state == "ended" && repeated.snapshot == LayoutSnapshot(revision: 1, values: [:]), "a repeated end answers at the accepted revision")

        let published = FakeLayoutBackend(), publishedURL = folder.appendingPathComponent("published.json")
        let caughtUp = LayoutActivityController(backend: published, store: FileReceiptStore(url: publishedURL, mode: .redacted))
        let shown = try await caughtUp.start(transcriptRequest("Shown"))
        _ = try await caughtUp.update(layoutUpdate(shown.id, transcript(1, "Shown later")))
        let reopened = LayoutActivityController(backend: published, store: FileReceiptStore(url: publishedURL, mode: .redacted))
        _ = try await reopened.end(layoutEnd(shown.id))
        expect(published.ends == ["end 1"], "a redacted end publishes the snapshot the system shows when it is the accepted one")
    }

    // AK-LIST-3, AK-UPDATE-10
    @MainActor private static func testFullLayoutReceipts() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let lagging = FakeLayoutBackend()
        lagging.delayObservation = true
        let persistent = LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url))
        let started = try await persistent.start(transcriptRequest("First words"))
        _ = try await persistent.update(layoutUpdate(started.id, transcript(2, "Second words")))
        let text = try fileText(url)
        expect(text.contains("Second words") && !text.contains("First words") && !text.contains("lockScreen"),
               "a full receipt keeps the latest snapshot and never the layout")
        let entry = try fileEntries(url)[0]
        try await verify(Set(entry.keys) == entryKeys && entry["id"] as? String == started.id && entry["activityKey"] as? String == "private"
            && entry["schemaVersion"] as? Int == 2 && entry["state"] as? String == "active" && entry["revision"] as? Int == 2
            && entry["fingerprint"] as? String == (try transcriptRequest("First words").fingerprint()), "a layout receipt entry has the documented members")
        expect(NSDictionary(dictionary: entry["content"] as? [String: Any] ?? [:]).isEqual(to: ["revision": 2, "values": ["transcript": "Second words"]]),
               "full content is the snapshot")
        let restart = LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url))
        try await verify(try await restart.list()[0].snapshot == transcript(2, "Second words"), "durable layout receipt preserves accepted state while OS publication lags")
        await expectError("STALE_REVISION") { _ = try await restart.update(layoutUpdate(started.id, transcript(1, "x"))) }
        _ = try await restart.update(layoutUpdate(started.id, transcript(2, "Second words")))
        expect(lagging.updates == 1, "a full receipt answers the same revision without the backend")
        await expectError("CONFLICT") { _ = try await restart.update(layoutUpdate(started.id, transcript(2, "Other words"))) }
        try await verify(try await restart.end(layoutEnd(started.id)).snapshot == transcript(2, "Second words"), "end publishes the accepted snapshot")
        let afterEnd = LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url))
        let repeated = try await afterEnd.end(layoutEnd(started.id))
        expect(repeated.state == "ended" && repeated.snapshot == transcript(2, "Second words") && repeated.activityKey == "private" && repeated.schemaVersion == 2,
               "a full layout tombstone survives a restart with its snapshot")
        await expectError("NOT_FOUND") { _ = try await afterEnd.update(layoutUpdate(started.id, transcript(3, "x"))) }
    }

    @MainActor private static func testRedactedLayoutReceipts() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let secrets = ["Whispered words", "Second whisper", "Third whisper", "Wrong whisper", "transcript"]
        func leaks() throws -> [String] { let text = try fileText(url); return secrets.filter(text.contains) }
        let lagging = FakeLayoutBackend()
        lagging.delayObservation = true
        let store = FileReceiptStore(url: url, mode: .redacted)
        expect(store.mode == .redacted && FileReceiptStore(url: url).mode == .full, "receipts are full unless the store is made redacted")
        let controller = LayoutActivityController(backend: lagging, store: store)
        let started = try await controller.start(transcriptRequest(secrets[0]))
        try await verify(try leaks().isEmpty, "a redacted receipt holds no snapshot string after start")
        _ = try await controller.update(layoutUpdate(started.id, transcript(2, secrets[1])))
        try await verify(try leaks().isEmpty, "a redacted receipt holds no snapshot string after update")
        try await verify(try await controller.list()[0].snapshot == transcript(2, secrets[1]), "within one process the accepted snapshot is still reported")
        let entry = try fileEntries(url)[0]
        try await verify(Set(entry.keys) == entryKeys && entry["revision"] as? Int == 2 && entry["state"] as? String == "active"
            && NSDictionary(dictionary: entry["content"] as? [String: Any] ?? [:]).isEqual(to: ["digest": try digest(transcript(2, secrets[1]))]),
               "redacted content is the SHA-256 of the snapshot's sorted-keys JSON")

        let restart = LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted))
        try await verify(try await restart.list()[0].snapshot == transcript(0, secrets[0]), "after a restart a redacted receipt reports what the system shows")
        await expectError("STALE_REVISION") { _ = try await restart.update(layoutUpdate(started.id, transcript(1, secrets[3]))) }
        let same = try await restart.update(layoutUpdate(started.id, transcript(2, secrets[1])))
        expect(same.snapshot == transcript(2, secrets[1]) && lagging.updates == 1, "an equal digest is an idempotent success with the request's snapshot")
        await expectError("CONFLICT") { _ = try await restart.update(layoutUpdate(started.id, transcript(2, secrets[3]))) }
        try await verify(try await restart.update(layoutUpdate(started.id, transcript(3, secrets[2]))).snapshot.revision == 3 && lagging.updates == 2,
               "a newer revision passes the redacted floor")
        try await verify(try leaks().isEmpty, "a redacted receipt holds no snapshot string after a restart and update")
        try await verify(try await restart.end(layoutEnd(started.id)).state == "ended", "redacted activities end")
        try await verify(try leaks().isEmpty && fileEntries(url)[0]["state"] as? String == "ended", "a redacted tombstone holds no snapshot string")

        let afterEnd = LayoutActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted))
        let repeated = try await afterEnd.end(layoutEnd(started.id))
        expect(repeated.state == "ended" && repeated.id == started.id && repeated.activityKey == "private" && repeated.snapshot == LayoutSnapshot(revision: 3, values: [:]),
               "a redacted tombstone answers end with an empty snapshot at its revision")
        await expectError("NOT_FOUND") { _ = try await afterEnd.update(layoutUpdate(started.id, transcript(4, secrets[3]))) }
        try await verify(try await afterEnd.list().isEmpty, "a tombstone without an OS activity is not listed")
        let attributes = try LiveActivityLayoutAttributes(request: transcriptRequest(secrets[0]), instanceID: started.id)
        lagging.activities = [LayoutActivity(id: started.id, attributes: attributes, snapshot: transcript(0, secrets[0]), state: "active")]
        let shown = try await afterEnd.end(layoutEnd(started.id))
        expect(shown.state == "ended" && shown.snapshot == transcript(0, secrets[0]), "a redacted tombstone reports what the system still shows")
        let listed = try await afterEnd.list()
        expect(listed.count == 1 && listed[0].state == "ended" && listed[0].snapshot == transcript(0, secrets[0]), "a redacted tombstone keeps the activity ended in list")
        lagging.activities = []
        let again = try await afterEnd.start(transcriptRequest(secrets[0]))
        try await verify(again.id != started.id && (try leaks().isEmpty), "a new start after a redacted tombstone gets a new handle")

        let retentionURL = folder.appendingPathComponent("retention.json")
        let retentionBackend = FakeLayoutBackend()
        let retention = LayoutActivityController(backend: retentionBackend, store: FileReceiptStore(url: retentionURL, mode: .redacted))
        var ids: [String] = []
        for index in 0..<130 {
            let activity = try await retention.start(meterRequest("retention:\(index)"))
            ids.append(activity.id)
            _ = try await retention.end(layoutEnd(activity.id))
        }
        try await verify(try fileEntries(retentionURL).count == 128, "redacted tombstones stay bounded")
        let restored = LayoutActivityController(backend: retentionBackend, store: FileReceiptStore(url: retentionURL, mode: .redacted))
        try await verify(try await restored.end(layoutEnd(ids[129])).state == "ended", "the latest redacted tombstone survives a restart")
        await expectError("NOT_FOUND") { _ = try await restored.end(layoutEnd(ids[0])) }

        let switched = folder.appendingPathComponent("switched.json")
        let switching = FakeLayoutBackend()
        switching.delayObservation = true
        let full = LayoutActivityController(backend: switching, store: FileReceiptStore(url: switched))
        let plain = try await full.start(transcriptRequest(secrets[0]))
        try await verify(try fileText(switched).contains(secrets[0]), "a full receipt holds the snapshot text")
        let redacted = LayoutActivityController(backend: switching, store: FileReceiptStore(url: switched, mode: .redacted))
        try await verify(try await redacted.list().count == 1 && !(try fileText(switched).contains(secrets[0])), "loading in redacted mode removes stored snapshot text")
        _ = try await redacted.update(layoutUpdate(plain.id, transcript(1, secrets[1])))
        let reopened = LayoutActivityController(backend: switching, store: FileReceiptStore(url: switched))
        await expectError("STALE_REVISION") { _ = try await reopened.update(layoutUpdate(plain.id, transcript(0, secrets[0]))) }
        _ = try await reopened.update(layoutUpdate(plain.id, transcript(2, secrets[2])))
        let mixed = try fileEntries(switched)
        try await verify(mixed.count == 1 && (try fileText(switched).contains(secrets[2])), "a full store writes snapshots again")
    }

    // AK-LIST-3
    @MainActor private static func testReceiptFileRules() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func entry(_ id: String, version: Int = 2, content: StoredReceipt.Content = .digest("d"), revision: Int64 = 0) -> StoredReceipt {
            StoredReceipt(id: id, summary: ReceiptSummary(activityKey: "key", schemaVersion: version, fingerprint: "f"), state: "ended",
                          revision: revision, content: content)
        }
        func expectUnreadable(_ entries: [StoredReceipt]) async throws {
            let url = folder.appendingPathComponent(UUID().uuidString + ".json")
            try FileReceiptStore(url: url).save(entries)
            await expectError("NATIVE_ERROR") { _ = try FileReceiptStore(url: url).load() }
        }
        let readable = folder.appendingPathComponent("readable.json")
        try FileReceiptStore(url: readable).save([entry("b"), entry("d", content: .layout(transcript(7, "words")), revision: 7)])
        let loaded = try FileReceiptStore(url: readable).load()
        expect(loaded.map(\.id) == ["b", "d"] && loaded.map(\.revision) == [0, 7], "entries load in order")
        // A full receipt keeps the values in plain text, private to the user, and on iOS protected until the first unlock.
        let permissions = try FileManager.default.attributesOfItem(atPath: readable.path)[.posixPermissions] as? Int
        expect(permissions == 0o600, "the receipt file is private to the user")
        let plain = try fileText(readable)
        expect(plain.contains("words"), "a full receipt holds the values in plain text")
        expect(FileReceiptStore.protection == .completeFileProtectionUntilFirstUserAuthentication,
               "on iOS the file is readable once the device was unlocked after a restart")
        // a stored snapshot must be valid, its revision must match, and only contract v2 is read
        try await expectUnreadable([entry("a", content: .layout(LayoutSnapshot(revision: 0, values: ["1a": .bool(true)])))])
        try await expectUnreadable([entry("a", content: .layout(transcript(2, "words")), revision: 1)])
        try await expectUnreadable([entry("a", version: 1)])
        try await expectUnreadable([entry("a", version: 3)])
        try await expectUnreadable((0...256).map { entry("id\($0)") })
        try FileReceiptStore(url: readable).save((0..<256).map { entry("id\($0)") })
        try await verify(try FileReceiptStore(url: readable).load().count == 256, "the file keeps up to 256 receipts")
        // A file that cannot be read, or a folder that cannot hold one, is a native error.
        let corrupt = folder.appendingPathComponent("corrupt.json")
        try Data("invalid JSON".utf8).write(to: corrupt)
        await expectError("NATIVE_ERROR") { _ = try FileReceiptStore(url: corrupt).load() }
        await expectError("NATIVE_ERROR") { try FileReceiptStore(url: corrupt.appendingPathComponent("receipts.json")).save([]) }
        let odd = folder.appendingPathComponent("odd.json")
        for text in [#"{"receipts":[]}"#, #"[{"id":"a"}]"#, #"[{"id":"a","activityKey":"k","schemaVersion":2,"state":"ended","revision":0,"fingerprint":"f","content":{"digest":"d"},"layout":{}}]"#,
                     #"[{"id":"a","activityKey":"k","schemaVersion":2,"state":"ended","revision":0,"fingerprint":"f","content":{"digest":"d","revision":0}}]"#,
                     #"[{"id":"a","activityKey":"k","schemaVersion":2,"state":"ended","revision":0,"fingerprint":"f","content":"d"}]"#] {
            try Data(text.utf8).write(to: odd)
            await expectError("NATIVE_ERROR") { _ = try FileReceiptStore(url: odd).load() }
        }
        try Data(repeating: 0x20, count: 2_097_153).write(to: odd)
        await expectError("NATIVE_ERROR") { _ = try FileReceiptStore(url: odd).load() }
        let huge = LayoutSnapshot(revision: 0, values: Dictionary(uniqueKeysWithValues: (0..<32).map { ("k\($0)", LayoutValue.string(String(repeating: "\u{1F600}", count: 1000))) }))
        await expectError("NATIVE_ERROR") { try FileReceiptStore(url: odd).save((0..<32).map { entry("id\($0)", content: .layout(huge)) }) }

        struct Config: Decodable { let receipts: ReceiptMode? }
        try await verify(try JSONDecoder().decode(Config.self, from: Data(#"{"receipts":"redacted"}"#.utf8)).receipts == .redacted
            && (try JSONDecoder().decode(Config.self, from: Data(#"{"receipts":"full"}"#.utf8)).receipts) == .full
            && (try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).receipts) == nil, "the receipt mode decodes from a configuration")
        expect((try? JSONDecoder().decode(Config.self, from: Data(#"{"receipts":"hashed"}"#.utf8))) == nil, "an unknown receipt mode is rejected")
    }
}
