#if os(iOS)
import ActivityKit
import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif
#if canImport(ActivityKitCore)
import ActivityKitCore
#endif

/// ActivityKit for layout activities (`Activity<LiveActivityLayoutAttributes>`), with the presentations of the call
/// and the observer of new activities and their states.
@available(iOS 16.2, *)
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

    func list() async -> [LayoutActivity] { system.activities.map { describe($0) } }

    func start(_ attributes: LiveActivityLayoutAttributes, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        let presentation = presentations.start(key: attributes.activityKey)
        let (activity, score) = try system.start(attributes, state: snapshot, relevance: presentation?.relevance, push: presentation?.push,
                                                 transient: presentation?.transient ?? false, scheduled: presentation?.scheduled)
        observer.watch(activity, announce: true)
        return describe(activity, relevance: score)
    }

    func update(_ activity: LayoutActivity, snapshot: LayoutSnapshot) async throws -> LayoutActivity {
        let presentation = presentations.update(id: activity.id, revision: snapshot.revision)
        let (updated, score) = try await system.update(activity.id, state: snapshot, relevance: presentation?.relevance, alert: presentation?.alert)
        return describe(updated, relevance: score)
    }

    func end(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        let score = try await system.end(activity.id, state: activity.snapshot, policy: policy, relevance: presentations.end(id: activity.id))
        return ended(activity, relevance: score)
    }

    func endKeepingContent(_ activity: LayoutActivity, policy: EndPolicy) async throws -> LayoutActivity {
        let score = try await system.end(activity.id, state: nil, policy: policy, relevance: presentations.end(id: activity.id))
        return ended(activity, relevance: score)
    }

    private func ended(_ activity: LayoutActivity, relevance: Double) -> LayoutActivity {
        LayoutActivity(id: activity.id, attributes: activity.attributes, snapshot: activity.snapshot, state: "ended",
                       degradedFeatures: activity.degradedFeatures, relevance: relevance)
    }

    private func describe(_ activity: Activity<LiveActivityLayoutAttributes>, relevance: Double? = nil) -> LayoutActivity {
        LayoutActivity(id: activity.attributes.instanceID, attributes: activity.attributes, snapshot: system.state(of: activity),
                       state: system.lifecycle(of: activity),
                       degradedFeatures: activity.attributes.document.unknownCustomViews(registered: customViews),
                       relevance: relevance ?? system.relevance(of: activity))
    }
}
#endif
