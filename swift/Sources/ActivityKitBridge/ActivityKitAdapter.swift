#if os(iOS)
import ActivityKit
import Foundation
import UIKit
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

/// A content state that may carry a stale time.
protocol StaleDated { var staleAt: Int64? { get } }
extension LayoutSnapshot: StaleDated {}

/// The attributes type the bridge publishes; it carries the handle and the contract version.
@available(iOS 16.1, *)
protocol BridgeActivityAttributes: ActivityAttributes where ContentState: StaleDated {
    var instanceID: String { get }
    var schemaVersion: Int { get }
}
@available(iOS 16.1, *)
extension LiveActivityLayoutAttributes: BridgeActivityAttributes {}

/// The ActivityKit calls of one attributes type, from the plugin's adapter, with the relevance and the alert that
/// ActivityKit takes beside the content.
@available(iOS 16.1, *)
@MainActor
struct ActivityKitAdapter<Attributes: BridgeActivityAttributes> {
    typealias SystemActivity = Activity<Attributes>
    let schemaVersion: Int

    func preflightStart() throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true else {
            throw ActivityFailure("CONFIGURATION_REQUIRED", "Enable NSSupportsLiveActivities in the host app and embed the widget extension.")
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ActivityFailure("PERMISSION_DENIED", "Live Activities are disabled in system settings.")
        }
        guard UIApplication.shared.applicationState == .active else {
            throw ActivityFailure("CONFIGURATION_REQUIRED", "Start local Live Activities while the host app is in the foreground.")
        }
    }

    var activities: [SystemActivity] {
        SystemActivity.activities.filter { $0.attributes.schemaVersion == schemaVersion }
    }

    func start(_ attributes: Attributes, state: Attributes.ContentState, relevance: Double? = nil) throws -> SystemActivity {
        do {
            if #available(iOS 16.2, *) {
                return try SystemActivity.request(attributes: attributes, content: content(state, relevance: relevance), pushType: nil)
            }
            try requireLegacyState(state)
            return try SystemActivity.request(attributes: attributes, contentState: state, pushType: nil)
        } catch let failure as ActivityFailure { throw failure }
        catch let failure as ActivityAuthorizationError { throw mapAuthorizationError(failure) }
        catch { throw ActivityFailure("NATIVE_ERROR", "ActivityKit could not start the activity.") }
    }

    func update(_ id: String, state: Attributes.ContentState, relevance: Double? = nil, alert: AlertText? = nil) async throws -> SystemActivity {
        let activity = try find(id)
        let configuration = alert.map {
            AlertConfiguration(title: LocalizedStringResource(stringLiteral: $0.title), body: LocalizedStringResource(stringLiteral: $0.body),
                               sound: .default)
        }
        if #available(iOS 16.2, *) {
            await activity.update(content(state, relevance: relevance), alertConfiguration: configuration)
        } else {
            try requireLegacyState(state)
            await activity.update(using: state, alertConfiguration: configuration)
        }
        return activity
    }

    /// Ends the activity showing `state`, the last accepted one, or without new content when `state` is nil: the
    /// system then keeps what it last published.
    func end(_ id: String, state: Attributes.ContentState?, policy: EndPolicy) async throws {
        let activity = try find(id)
        let dismissal: ActivityUIDismissalPolicy
        switch policy.kind {
        case "immediate": dismissal = .immediate
        case "after":
            guard let at = policy.at else { throw ActivityFailure("INVALID_INPUT", "A dismissal timestamp is required.") }
            dismissal = .after(Date(timeIntervalSince1970: Double(at) / 1000))
        default: dismissal = .default
        }
        if #available(iOS 16.2, *) { await activity.end(state.map { content($0, relevance: nil) }, dismissalPolicy: dismissal) }
        else { await activity.end(using: state, dismissalPolicy: dismissal) }
    }

    func state(of activity: SystemActivity) -> Attributes.ContentState {
        if #available(iOS 16.2, *) { return activity.content.state }
        return activity.contentState
    }

    func lifecycle(of activity: SystemActivity) -> String { Self.name(activity.activityState) }

    /// The contract's name of an ActivityKit state.
    nonisolated static func name(_ state: ActivityState) -> String {
        if #available(iOS 16.2, *), state == .stale { return "stale" }
        switch state {
        case .active: return "active"
        case .ended: return "ended"
        case .dismissed: return "dismissed"
        default: return "unknown"
        }
    }

    private func find(_ id: String) throws -> SystemActivity {
        guard let activity = SystemActivity.activities.first(where: { $0.attributes.instanceID == id }) else {
            throw ActivityFailure("NOT_FOUND", "The activity is no longer available.")
        }
        return activity
    }

    @available(iOS 16.2, *)
    private func content(_ state: Attributes.ContentState, relevance: Double?) -> ActivityContent<Attributes.ContentState> {
        ActivityContent(state: state, staleDate: state.staleAt.map { Date(timeIntervalSince1970: Double($0) / 1000) },
                        relevanceScore: relevance ?? 0)
    }

    private func requireLegacyState(_ state: Attributes.ContentState) throws {
        if state.staleAt != nil {
            throw ActivityFailure("UNSUPPORTED_FEATURE", "staleAt requires iOS 16.2 or later.")
        }
    }

    private func mapAuthorizationError(_ error: ActivityAuthorizationError) -> ActivityFailure {
        switch error {
        case .attributesTooLarge: return ActivityFailure("PAYLOAD_TOO_LARGE", "ActivityKit rejected the payload size.")
        case .denied: return ActivityFailure("PERMISSION_DENIED", "Live Activities are disabled.")
        case .globalMaximumExceeded, .targetMaximumExceeded: return ActivityFailure("SYSTEM_LIMIT", "The system Live Activity limit was reached.")
        case .unsupported, .unsupportedTarget: return ActivityFailure("UNSUPPORTED_FEATURE", "Live Activities are unavailable on this device.")
        case .unentitled, .visibility: return ActivityFailure("CONFIGURATION_REQUIRED", "Check host app Live Activity configuration and foreground state.")
        default: return ActivityFailure("NATIVE_ERROR", "ActivityKit could not authorize the activity.")
        }
    }
}
#endif
