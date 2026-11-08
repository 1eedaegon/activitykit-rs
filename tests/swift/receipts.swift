import CryptoKit
import Foundation

/// A v1 backend whose OS read keeps showing the started snapshot and that records how activities end.
@MainActor
final class LaggingTemplateBackend: ActivityBackend {
    var activities: [NativeActivity] = []
    /// `end <revision>` published that snapshot, `keep` published nothing.
    var ends: [String] = []
    func preflightStart() throws {}
    func list() async -> [NativeActivity] { activities }
    func start(_ attributes: LiveActivityAttributes, snapshot: ActivitySnapshot) async throws -> NativeActivity {
        let activity = NativeActivity(id: attributes.instanceID, attributes: attributes, snapshot: snapshot, state: "active")
        activities.append(activity)
        return activity
    }
    func update(_ activity: NativeActivity, snapshot: ActivitySnapshot) async throws -> NativeActivity {
        NativeActivity(id: activity.id, attributes: activity.attributes, snapshot: snapshot, state: "active")
    }
    func end(_ activity: NativeActivity, policy: EndPolicy) async throws -> NativeActivity {
        ends.append("end \(activity.snapshot.revision)")
        activities = activities.filter { $0.id != activity.id }
        return NativeActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended")
    }
    func endKeepingContent(_ activity: NativeActivity, policy: EndPolicy) async throws -> NativeActivity {
        ends.append("keep")
        activities = activities.filter { $0.id != activity.id }
        return NativeActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended")
    }
}

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
    static func hidden(_ revision: Int64, _ title: String, _ status: String) -> ActivitySnapshot {
        ActivitySnapshot(revision: revision, title: title, status: status, progress: 0.5, timer: nil, staleAt: nil)
    }
    static let entryKeys: Set<String> = ["id", "activityKey", "schemaVersion", "state", "revision", "fingerprint", "content"]

    @MainActor static func testReceipts() async throws {
        try await testFullLayoutReceipts()
        try await testRedactedLayoutReceipts()
        try await testRedactedTemplateReceipts()
        try await testRedactedEndAfterRestart()
        try await testGuessableRedaction()
        try await testReceiptMigration()
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

        let templateURL = folder.appendingPathComponent("template.json")
        let template = LaggingTemplateBackend()
        let v1 = LiveActivityController(backend: template, store: FileReceiptStore(url: templateURL, mode: .redacted))
        let started = try await v1.start(request("v1", hidden(0, "Recording", "Status")))
        _ = try await v1.update(UpdateRequest(id: started.id, snapshot: hidden(1, "Saved", "Status")))
        let v1Restart = LiveActivityController(backend: template, store: FileReceiptStore(url: templateURL, mode: .redacted))
        let v1Ended = try await v1Restart.end(EndRequest(id: started.id, policy: EndPolicy(kind: "immediate", at: nil)))
        expect(template.ends == ["keep"] && v1Ended.state == "ended" && v1Ended.snapshot.revision == 0,
               "a lagging redacted v1 end after a restart publishes no older snapshot")
        let v1Tombstone = try fileEntries(templateURL)[0]
        try await verify(v1Tombstone["revision"] as? Int == 1
            && NSDictionary(dictionary: v1Tombstone["content"] as? [String: Any] ?? [:]).isEqual(to: ["digest": try digest(hidden(1, "Saved", "Status"))]),
               "the redacted v1 tombstone keeps the accepted revision")
    }

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

        let templateURL = folder.appendingPathComponent("template.json")
        let template = LiveActivityController(backend: FakeBackend(), store: FileReceiptStore(url: templateURL))
        let v1 = try await template.start(request("v1", hidden(0, "Title", "Status")))
        let v1Entry = try fileEntries(templateURL)[0]
        expect(Set(v1Entry.keys) == entryKeys.union(["template"]) && v1Entry["template"] as? String == "progress" && v1Entry["schemaVersion"] as? Int == 1
            && v1Entry["id"] as? String == v1.id, "a v1 receipt entry also names its template")
        expect(NSDictionary(dictionary: v1Entry["content"] as? [String: Any] ?? [:]).isEqual(to: ["revision": 0, "title": "Title", "status": "Status", "progress": 0.5]),
               "v1 full content is the v1 snapshot")
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

    @MainActor private static func testRedactedTemplateReceipts() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("receipts.json")
        let secrets = ["Hidden title", "Hidden status", "Later status", "Wrong status"]
        func leaks() throws -> [String] { let text = try fileText(url); return secrets.filter(text.contains) }
        let lagging = FakeBackend()
        lagging.delayObservation = true
        let controller = LiveActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted))
        let started = try await controller.start(request("private", hidden(0, secrets[0], secrets[1])))
        _ = try await controller.update(UpdateRequest(id: started.id, snapshot: hidden(2, secrets[0], secrets[2])))
        try await verify(try leaks().isEmpty, "a redacted v1 receipt holds no snapshot string")
        try await verify(try await controller.list()[0].snapshot.status == secrets[2], "within one process the accepted v1 snapshot is still reported")
        let entry = try fileEntries(url)[0]
        try await verify(Set(entry.keys) == entryKeys.union(["template"]) && entry["template"] as? String == "progress"
            && NSDictionary(dictionary: entry["content"] as? [String: Any] ?? [:]).isEqual(to: ["digest": try digest(hidden(2, secrets[0], secrets[2]))]),
               "a redacted v1 entry keeps its template and a digest")

        let restart = LiveActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted))
        let listed = try await restart.list()
        expect(listed[0].snapshot.revision == 0 && listed[0].snapshot.status == secrets[1], "after a restart a redacted v1 receipt reports what the system shows")
        await expectError("STALE_REVISION") { _ = try await restart.update(UpdateRequest(id: started.id, snapshot: hidden(1, secrets[0], secrets[3]))) }
        let same = try await restart.update(UpdateRequest(id: started.id, snapshot: hidden(2, secrets[0], secrets[2])))
        expect(same.snapshot.revision == 2 && same.snapshot.status == secrets[2] && lagging.updates == 1, "an equal v1 digest is an idempotent success")
        await expectError("CONFLICT") { _ = try await restart.update(UpdateRequest(id: started.id, snapshot: hidden(2, secrets[0], secrets[3]))) }
        try await verify(try await restart.end(EndRequest(id: started.id, policy: EndPolicy(kind: "immediate", at: nil))).state == "ended", "redacted v1 activities end")
        try await verify(try leaks().isEmpty, "a redacted v1 tombstone holds no snapshot string")
        let afterEnd = LiveActivityController(backend: lagging, store: FileReceiptStore(url: url, mode: .redacted))
        let repeated = try await afterEnd.end(EndRequest(id: started.id, policy: EndPolicy(kind: "immediate", at: nil)))
        expect(repeated.state == "ended" && repeated.id == started.id && repeated.template == "progress" && repeated.activityKey == "private"
            && repeated.snapshot == ActivitySnapshot(revision: 2, title: "", status: "", progress: nil, timer: nil, staleAt: nil),
               "a redacted v1 tombstone answers end with an empty snapshot at the accepted revision")
        await expectError("NOT_FOUND") { _ = try await afterEnd.update(UpdateRequest(id: started.id, snapshot: hidden(3, secrets[0], secrets[3]))) }
        try await verify(try await afterEnd.start(request("private", hidden(0, secrets[0], secrets[1]))).id != started.id, "a new v1 start after a redacted tombstone gets a new handle")
    }

    @MainActor private static func testReceiptMigration() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let attributes = try LiveActivityAttributes(request: request("legacy", hidden(0, "Old title", "Old status")), instanceID: "la-ios-OLD")
        let napSnapshot = ActivitySnapshot(revision: 1, title: "Nap title", status: "Nap status", progress: nil, timer: ActivityTimer(startedAt: 1_000, endsAt: 121_000), staleAt: nil)
        let nap = try LiveActivityAttributes(request: StartRequest(activityKey: "nap", schemaVersion: 1, template: "timer", fallback: "none", snapshot: napSnapshot), instanceID: "la-ios-GONE")
        func writeLegacy(_ url: URL, revision: Int64 = 3) throws {
            try JSONEncoder().encode([NativeActivity(id: "la-ios-OLD", attributes: attributes, snapshot: hidden(revision, "Old title", "Old status"), state: "active"),
                                      NativeActivity(id: "la-ios-GONE", attributes: nap, snapshot: napSnapshot, state: "ended")]).write(to: url)
        }
        func osBackend() -> FakeBackend {
            let backend = FakeBackend()
            backend.activities = [NativeActivity(id: "la-ios-OLD", attributes: attributes, snapshot: hidden(0, "Old title", "Old status"), state: "active")]
            return backend
        }
        let gone = EndRequest(id: "la-ios-GONE", policy: EndPolicy(kind: "immediate", at: nil))

        let fullFolder = folder.appendingPathComponent("full")
        try FileManager.default.createDirectory(at: fullFolder, withIntermediateDirectories: true)
        let legacy = fullFolder.appendingPathComponent("receipts-v1.json"), url = fullFolder.appendingPathComponent("receipts-v2.json")
        try writeLegacy(legacy)
        let migrated = LiveActivityController(backend: osBackend(), store: FileReceiptStore.store(in: fullFolder, mode: .full))
        let list = try await migrated.list()
        expect(list.count == 1 && list[0].snapshot.revision == 3 && list[0].snapshot.title == "Old title", "migrated v1 receipts keep the accepted state")
        expect(!FileManager.default.fileExists(atPath: legacy.path) && FileManager.default.fileExists(atPath: url.path), "the v1 file is converted and deleted")
        let entries = try fileEntries(url)
        expect(entries.count == 2 && entries.allSatisfy { Set($0.keys) == entryKeys.union(["template"]) && $0["schemaVersion"] as? Int == 1 }
            && entries.map { $0["template"] as? String } == ["progress", "timer"] && entries.map { $0["revision"] as? Int } == [3, 1]
            && entries[0]["fingerprint"] as? String == attributes.initialFingerprint && entries[0]["activityKey"] as? String == "legacy",
               "migrated entries carry the v1 attributes that records need")
        await expectError("STALE_REVISION") { _ = try await migrated.update(UpdateRequest(id: "la-ios-OLD", snapshot: hidden(2, "Old title", "Old status"))) }
        let tombstone = try await migrated.end(gone)
        expect(tombstone.state == "ended" && tombstone.template == "timer" && tombstone.activityKey == "nap" && tombstone.snapshot.timer?.endsAt == 121_000,
               "migrated tombstones keep end idempotent")
        try writeLegacy(legacy, revision: 5)
        let again = LiveActivityController(backend: osBackend(), store: FileReceiptStore.store(in: fullFolder, mode: .full))
        try await verify(try await again.list()[0].snapshot.revision == 5 && (try fileEntries(url).count) == 2 && !FileManager.default.fileExists(atPath: legacy.path),
               "a v1 file that reappears replaces the entries of its activities")

        let redactedFolder = folder.appendingPathComponent("redacted")
        try FileManager.default.createDirectory(at: redactedFolder, withIntermediateDirectories: true)
        let redactedLegacy = redactedFolder.appendingPathComponent("receipts-v1.json"), redactedURL = redactedFolder.appendingPathComponent("receipts-v2.json")
        try writeLegacy(redactedLegacy)
        let redacted = LiveActivityController(backend: osBackend(), store: FileReceiptStore.store(in: redactedFolder, mode: .redacted))
        try await verify(try await redacted.list()[0].snapshot.revision == 0, "a migrated redacted receipt reports what the system shows")
        let text = try fileText(redactedURL)
        expect(!FileManager.default.fileExists(atPath: redactedLegacy.path) && ["Old title", "Old status", "Nap title", "Nap status"].allSatisfy { !text.contains($0) },
               "redacted migration removes the plaintext left by earlier versions")
        await expectError("STALE_REVISION") { _ = try await redacted.update(UpdateRequest(id: "la-ios-OLD", snapshot: hidden(2, "Old title", "Old status"))) }
        try await verify(try await redacted.update(UpdateRequest(id: "la-ios-OLD", snapshot: hidden(3, "Old title", "Old status"))).snapshot.revision == 3,
               "a migrated digest still answers the same revision")
        let redactedTombstone = try await redacted.end(gone)
        expect(redactedTombstone.state == "ended" && redactedTombstone.template == "timer" && redactedTombstone.snapshot.title.isEmpty
            && redactedTombstone.snapshot.revision == 1, "a migrated redacted tombstone keeps end idempotent")

        let brokenFolder = folder.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: brokenFolder, withIntermediateDirectories: true)
        let brokenLegacy = brokenFolder.appendingPathComponent("receipts-v1.json")
        try Data("invalid JSON".utf8).write(to: brokenLegacy)
        let broken = LiveActivityController(backend: osBackend(), store: FileReceiptStore.store(in: brokenFolder, mode: .redacted))
        await expectError("NATIVE_ERROR") { _ = try await broken.list() }
        await expectError("NATIVE_ERROR") { _ = try await broken.start(request("legacy", hidden(0, "Old title", "Old status"))) }
        let brokenLayout = LayoutActivityController(backend: FakeLayoutBackend(), store: FileReceiptStore.store(in: brokenFolder, mode: .full))
        await expectError("NATIVE_ERROR") { _ = try await brokenLayout.list() }
        expect(FileManager.default.fileExists(atPath: brokenLegacy.path) && !FileManager.default.fileExists(atPath: brokenFolder.appendingPathComponent("receipts-v2.json").path),
               "a v1 file that cannot be read stays an error and is kept")
        try JSONEncoder().encode([NativeActivity(id: "x", attributes: attributes, snapshot: hidden(0, " ", "Old status"), state: "active")]).write(to: brokenLegacy)
        await expectError("NATIVE_ERROR") { _ = try FileReceiptStore.store(in: brokenFolder, mode: .full).load() }
        try Data(repeating: 0x20, count: 1_048_577).write(to: brokenLegacy)
        await expectError("NATIVE_ERROR") { _ = try FileReceiptStore.store(in: brokenFolder, mode: .full).load() }
    }

    @MainActor private static func testReceiptFileRules() async throws {
        let folder = try receiptFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        func entry(_ id: String, version: Int = 2, template: String? = nil, content: StoredReceipt.Content = .digest("d"), revision: Int64 = 0) -> StoredReceipt {
            StoredReceipt(id: id, summary: ReceiptSummary(activityKey: "key", schemaVersion: version, template: template, fingerprint: "f"), state: "ended",
                          revision: revision, content: content)
        }
        func expectUnreadable(_ label: String, _ entries: [StoredReceipt]) async throws {
            let url = folder.appendingPathComponent(UUID().uuidString + ".json")
            try FileReceiptStore(url: url).save(entries)
            await expectError("NATIVE_ERROR") { _ = try FileReceiptStore(url: url).load() }
            expect(true, label)
        }
        let readable = folder.appendingPathComponent("readable.json")
        let mixed = [entry("a", version: 1, template: "timer"), entry("b"), entry("c", version: 1, template: "progress", content: .template(hidden(4, "T", "S")), revision: 4),
                     entry("d", content: .layout(transcript(7, "words")), revision: 7)]
        try FileReceiptStore(url: readable).save(mixed)
        let loaded = try FileReceiptStore(url: readable).load()
        expect(loaded.map(\.id) == ["a", "b", "c", "d"] && loaded.map(\.revision) == [0, 0, 4, 7] && loaded.map(\.summary.template) == ["timer", nil, "progress", nil],
               "entries of both contract versions load in order")
        let permissions = try FileManager.default.attributesOfItem(atPath: readable.path)[.posixPermissions] as? Int
        expect(permissions == 0o600, "the receipt file is private to the user")
        try await expectUnreadable("a v1 entry needs a template", [entry("a", version: 1)])
        try await expectUnreadable("a v1 snapshot must match its template", [entry("a", version: 1, template: "timer", content: .template(hidden(0, "T", "S")))])
        try await expectUnreadable("a stored snapshot must be valid", [entry("a", content: .layout(LayoutSnapshot(revision: 0, values: ["1a": .bool(true)])))])
        try await expectUnreadable("a stored revision must match its snapshot", [entry("a", content: .layout(transcript(2, "words")), revision: 1)])
        try await expectUnreadable("a v2 entry cannot hold a v1 snapshot", [entry("a", content: .template(hidden(0, "T", "S")))])
        try await expectUnreadable("a v1 entry cannot hold a v2 snapshot", [entry("a", version: 1, template: "progress", content: .layout(transcript(0, "words")))])
        try await expectUnreadable("an unknown contract version is unreadable", [entry("a", version: 3)])
        try await expectUnreadable("at most 256 receipts per contract version", (0...256).map { entry("id\($0)") })
        try FileReceiptStore(url: readable).save((0..<256).map { entry("id\($0)") } + (0..<256).map { entry("v1-\($0)", version: 1, template: "progress") })
        try await verify(try FileReceiptStore(url: readable).load().count == 512, "each contract version keeps up to 256 receipts")
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

        let shared = folder.appendingPathComponent("shared.json")
        let template = LiveActivityController(backend: FakeBackend(), store: FileReceiptStore(url: shared))
        let layout = LayoutActivityController(backend: FakeLayoutBackend(), store: FileReceiptStore(url: shared))
        let v1 = try await template.start(request("two-stores"))
        let v2 = try await layout.start(meterRequest("two-stores"))
        _ = try await template.update(UpdateRequest(id: v1.id, snapshot: snapshot(1, 0.5)))
        _ = try await layout.update(layoutUpdate(v2.id, meter(1, 0.5)))
        _ = try await template.end(EndRequest(id: v1.id, policy: EndPolicy(kind: "immediate", at: nil)))
        let both = try FileReceiptStore(url: shared).load()
        expect(both.count == 2 && both.first { $0.id == v2.id }?.revision == 1 && both.first { $0.id == v1.id }?.state == "ended",
               "two stores on one file keep each other's receipts")

        struct Config: Decodable { let receipts: ReceiptMode? }
        try await verify(try JSONDecoder().decode(Config.self, from: Data(#"{"receipts":"redacted"}"#.utf8)).receipts == .redacted
            && (try JSONDecoder().decode(Config.self, from: Data(#"{"receipts":"full"}"#.utf8)).receipts) == .full
            && (try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).receipts) == nil, "the receipt mode decodes from the plugin configuration")
        expect((try? JSONDecoder().decode(Config.self, from: Data(#"{"receipts":"hashed"}"#.utf8))) == nil, "an unknown receipt mode is rejected")
    }
}
