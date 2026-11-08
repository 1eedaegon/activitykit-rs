#if os(iOS)
import ActivityKit
import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif
#if canImport(ActivityKitCore)
import ActivityKitCore
#endif

/// ActivityKit for layout activities (`Activity<LiveActivityLayoutAttributes>`), as in the plugin, with the
/// presentations of the call and the observer of states.
@available(iOS 16.1, *)
@MainActor
final class LayoutActivityKitBackend: LayoutActivityBackend {
    private let system = ActivityKitAdapter<LiveActivityLayoutAttributes>(schemaVersion: 2)
    /// The names that the app's `ActivityKitCustomViews` class registers, read once.
    private let customViews = CustomViewCatalog.names()
    private let presentations: Presentations
    private let observer: ActivityObserver

    init(presentations: Presentations, observer: ActivityObserver) {
        self.presentations = presentations
        self.observer = observer
    }

    func preflightStart() throws { try system.preflightStart() }

    func preflightLayoutWidget() throws { try LayoutWidgetPreflight.check(plugIns: Bundle.main.builtInPlugInsURL) }

    func list() async -> [LayoutActivity] { system.activities.map(describe) }

    func start(_ attributes: LiveActivityLayoutAttributes, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        let activity = try system.start(attributes, state: snapshot, relevance: presentations.start(key: attributes.activityKey))
        observer.watch(activity)
        return describe(activity)
    }

    func update(_ activity: LayoutActivity, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        let presentation = presentations.update(id: activity.id, revision: snapshot.revision)
        return describe(try await system.update(activity.id, state: snapshot, relevance: presentation?.relevance, alert: presentation?.alert))
    }

    func end(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        try await system.end(activity.id, state: activity.snapshot, policy: policy)
        return LayoutActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended",
                              degradedFeatures: activity.degradedFeatures)
    }

    func endKeepingContent(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        try await system.end(activity.id, state: nil, policy: policy)
        return LayoutActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended",
                              degradedFeatures: activity.degradedFeatures)
    }

    private func describe(_ activity: Activity<LiveActivityLayoutAttributes>) -> LayoutActivity {
        LayoutActivity(id: activity.attributes.instanceID, attributes: activity.attributes, snapshot: system.state(of: activity),
                       state: system.lifecycle(of: activity),
                       degradedFeatures: activity.attributes.document.unknownCustomViews(registered: customViews))
    }
}
#endif
