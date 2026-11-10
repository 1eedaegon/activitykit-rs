import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

/// A layout activity as the system reports it.
public struct LayoutActivity: Sendable {
    public let id: String
    public let attributes: LiveActivityLayoutAttributes
    public let snapshot: LayoutSnapshot
    public let state: String
    /// What the widget leaves out, such as `layout.custom.<name>` for a custom view the app does not register.
    public let degradedFeatures: [String]
    /// The content's relevance score, when the backend knows it.
    public let relevance: Double?
    public init(id: String, attributes: LiveActivityLayoutAttributes, snapshot: LayoutSnapshot, state: String, degradedFeatures: [String] = [],
                relevance: Double? = nil) {
        self.id = id; self.attributes = attributes; self.snapshot = snapshot; self.state = state; self.degradedFeatures = degradedFeatures
        self.relevance = relevance
    }
    public var record: LayoutActivityRecord {
        LayoutActivityRecord(id: id, activityKey: attributes.activityKey, schemaVersion: attributes.schemaVersion, snapshot: snapshot, state: state,
                             degradedFeatures: degradedFeatures, relevance: relevance)
    }
}

/// The result of the layout commands. It does not echo the layout.
public struct LayoutActivityRecord: Encodable, Sendable {
    public let id: String
    public let activityKey: String
    public let schemaVersion: Int
    public let snapshot: LayoutSnapshot
    public let state: String
    public let degradedFeatures: [String]
    /// The relevance score of the content; absent when only a receipt knows the activity.
    public let relevance: Double?
    init(id: String, activityKey: String, schemaVersion: Int, snapshot: LayoutSnapshot, state: String, degradedFeatures: [String] = [],
         relevance: Double? = nil) {
        self.id = id; self.activityKey = activityKey; self.schemaVersion = schemaVersion; self.snapshot = snapshot; self.state = state
        self.degradedFeatures = degradedFeatures; self.relevance = relevance
    }
}

@MainActor
public protocol LayoutActivityBackend: AnyObject {
    func preflightStart() throws
    /// Throws CONFIGURATION_REQUIRED unless a widget extension built from the layout template is embedded.
    func preflightLayoutWidget() throws
    func list() async -> [LayoutActivity]
    func start(_ attributes: LiveActivityLayoutAttributes, snapshot: LayoutSnapshot) async throws -> LayoutActivity
    func update(_ activity: LayoutActivity, snapshot: LayoutSnapshot) async throws -> LayoutActivity
    /// Ends the activity with `activity.snapshot` as its final content.
    func end(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity
    /// Ends the activity without new content, so the system keeps what it last published.
    func endKeepingContent(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity
}

extension LayoutActivityBackend {
    /// A backend that does not implement it ends with `activity.snapshot`.
    public func endKeepingContent(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        try await end(activity, policy: policy)
    }
}

/// The layout-widget start preflight: an embedded app extension whose Info.plist sets
/// `ActivityKitLayout` to the integer 2.
public enum LayoutWidgetPreflight {
    public static let infoKey = "ActivityKitLayout"
    public static let version = 2

    /// `plugIns` is the app's `Bundle.main.builtInPlugInsURL`.
    public static func check(plugIns: URL?) throws {
        let bundles = plugIns.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        guard bundles.contains(where: isLayoutWidget) else {
            throw ActivityFailure("CONFIGURATION_REQUIRED", "Embed a widget extension built from the layout template.")
        }
    }

    /// The Info.plist of every embedded layout widget extension.
    private static func layoutWidgets(plugIns: URL?) -> [[String: Any]] {
        let bundles = plugIns.flatMap { try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) } ?? []
        return bundles.compactMap(info).filter { $0[infoKey] as? Int == version }
    }

    private static func isLayoutWidget(_ bundle: URL) -> Bool { info(bundle)?[infoKey] as? Int == version }

    private static func info(_ bundle: URL) -> [String: Any]? {
        guard bundle.pathExtension == "appex", let data = try? Data(contentsOf: bundle.appendingPathComponent("Info.plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }

    /// The folder for `write_image`, created when missing: `activitykit/images` in the container of the App Group
    /// that the layout widget's Info.plist names. `container` is `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`.
    public static func imageFolder(plugIns: URL?, container: (String) -> URL?) throws -> URL {
        guard let group = layoutWidgets(plugIns: plugIns).lazy.compactMap({ $0[LayoutImageFolder.infoKey] as? String }).first, !group.isEmpty else {
            throw ActivityFailure("CONFIGURATION_REQUIRED", "The widget extension names no App Group under ActivityKitAppGroup.")
        }
        guard let folder = LayoutImageFolder.url(group: group, container: container) else {
            throw ActivityFailure("CONFIGURATION_REQUIRED", "The app has no container for the App Group of the widget extension.")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { throw ActivityFailure("NATIVE_ERROR", "The image folder could not be created.") }
        return folder
    }
}

/// The custom views that the app registers in its subclass of `ActivityKitCustomViewRegistry`, which is compiled into the app
/// target as well as into the widget extension. The bridge reads the names from the Objective-C class `ActivityKitCustomViews`.
public enum CustomViewCatalog {
    public static let className = "ActivityKitCustomViews"

    /// The registered names, or nil when the app has no such class.
    public static func names(className: String = className) -> Set<String>? {
        guard let registry = NSClassFromString(className) as? NSObject.Type else { return nil }
        let selector = NSSelectorFromString("viewNames")
        guard registry.responds(to: selector), let names = registry.perform(selector)?.takeUnretainedValue() as? [String] else { return nil }
        return Set(names)
    }
}

extension LayoutActivity: LifecycleActivity {
    typealias Attributes = LiveActivityLayoutAttributes
    static let schemaVersion = 2
    static let instancePrefix = "la-ios-layout-"
    static func content(_ snapshot: LayoutSnapshot) -> StoredReceipt.Content { .layout(snapshot) }
    static func snapshot(in content: StoredReceipt.Content) -> LayoutSnapshot? {
        if case .layout(let snapshot) = content { return snapshot } else { return nil }
    }
    static func revision(of snapshot: LayoutSnapshot) -> Int64 { snapshot.revision }
    static func sameContent(_ one: LayoutSnapshot, _ other: LayoutSnapshot) -> Bool { one.content == other.content }
    static func digest(of snapshot: LayoutSnapshot) throws -> String { try ReceiptDigest.of(snapshot.content) }
    static func record(_ entry: StoredReceipt) -> LayoutActivityRecord {
        LayoutActivityRecord(id: entry.id, activityKey: entry.summary.activityKey, schemaVersion: entry.summary.schemaVersion,
                             snapshot: snapshot(in: entry.content) ?? LayoutSnapshot(revision: entry.revision, values: [:]), state: entry.state)
    }
    var summary: ReceiptSummary {
        ReceiptSummary(activityKey: attributes.activityKey, schemaVersion: attributes.schemaVersion, fingerprint: attributes.initialFingerprint)
    }
    func with(snapshot: LayoutSnapshot, state: String) -> LayoutActivity {
        LayoutActivity(id: id, attributes: attributes, snapshot: snapshot, state: state, degradedFeatures: degradedFeatures, relevance: relevance)
    }
}

extension LifecycleBackend where Activity == LayoutActivity {
    init(_ backend: LayoutActivityBackend) {
        self.init(preflight: { try backend.preflightStart(); try backend.preflightLayoutWidget() }, list: { await backend.list() },
                  start: { try await backend.start($0, snapshot: $1) }, update: { try await backend.update($0, snapshot: $1) },
                  end: { try await backend.end($0, policy: $1) }, endKeepingContent: { try await backend.endKeepingContent($0, policy: $1) })
    }
}

/// The lifecycle of layout activities.
@MainActor
public final class LayoutActivityController {
    private let lifecycle: ActivityLifecycle<LayoutActivity>
    public init(backend: LayoutActivityBackend, store: FileReceiptStore? = nil) {
        lifecycle = ActivityLifecycle(backend: LifecycleBackend(backend), storage: store.map { .file($0) } ?? .memory())
    }

    public func start(_ request: LayoutRequest) async throws -> LayoutActivityRecord {
        try request.validate()
        return try await lifecycle.start(key: request.activityKey, fingerprint: request.fingerprint, snapshot: request.snapshot) { id in
            let attributes = try LiveActivityLayoutAttributes(request: request, instanceID: id)
            try PayloadLimit.check(attributes: attributes, snapshot: request.snapshot)
            return attributes
        }
    }

    /// The values must keep the keys and types accepted at start and satisfy the stored layout.
    public func update(_ request: LayoutUpdateRequest) async throws -> LayoutActivityRecord {
        try request.validate()
        return try await lifecycle.update(id: request.id, snapshot: request.snapshot,
            validate: { try request.snapshot.validate(replacing: $0.snapshot, in: $0.attributes.document) },
            check: { try PayloadLimit.check(attributes: $0.attributes, snapshot: request.snapshot) })
    }

    /// Final content must keep the keys and types accepted at start and satisfy the stored layout, as an update does.
    public func end(_ request: LayoutEndRequest) async throws -> LayoutActivityRecord {
        try request.validate()
        let content = request.snapshot.map { snapshot in
            ActivityLifecycle<LayoutActivity>.FinalContent(snapshot: snapshot,
                validate: { try snapshot.validate(replacing: $0.snapshot, in: $0.attributes.document) },
                check: { try PayloadLimit.check(attributes: $0.attributes, snapshot: snapshot) })
        }
        return try await lifecycle.end(id: request.id, policy: request.policy, content: content)
    }

    public func list() async throws -> [LayoutActivityRecord] {
        try await lifecycle.list()
    }
}
