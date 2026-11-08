#if os(iOS)
import ActivityKit
import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

/// A content state that may carry a stale date and a timestamp.
protocol StaleDated {
    var staleAt: Int64? { get }
    var timestamp: Int64? { get }
}
extension LayoutSnapshot: StaleDated {}

/// The attributes type the bridge publishes; it carries the handle and the contract version.
@available(iOS 16.2, *)
protocol BridgeActivityAttributes: ActivityAttributes where ContentState: StaleDated {
    var instanceID: String { get }
    var schemaVersion: Int { get }
}
@available(iOS 16.2, *)
extension LiveActivityLayoutAttributes: BridgeActivityAttributes {}

private func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

/// The ActivityKit calls of one attributes type (iOS 16.2 and later), with the relevance, the alert and the timestamp
/// that ActivityKit takes beside the content.
@available(iOS 16.2, *)
@MainActor
struct ActivityKitAdapter<Attributes: BridgeActivityAttributes> {
    typealias SystemActivity = Activity<Attributes>
    let schemaVersion: Int

    /// What ActivityKit does not check itself before a start. Whether the app may start one now, in the foreground or
    /// from a Live Activity intent, ActivityKit decides (`visibility`).
    func preflightStart() throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool == true else {
            throw ActivityFailure("CONFIGURATION_REQUIRED", "Enable NSSupportsLiveActivities in the host app and embed the widget extension.")
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw ActivityFailure("PERMISSION_DENIED", "Live Activities are disabled in system settings.")
        }
    }

    var activities: [SystemActivity] {
        SystemActivity.activities.filter { $0.attributes.schemaVersion == schemaVersion }
    }

    /// Starts the activity; the relevance score is the given one, else 0.
    func start(_ attributes: Attributes, state: Attributes.ContentState, relevance: Double?) throws -> (SystemActivity, Double) {
        let score = relevance ?? 0
        do {
            return (try SystemActivity.request(attributes: attributes, content: content(state, relevance: score), pushType: nil), score)
        } catch let failure as ActivityFailure { throw failure }
        catch let failure as ActivityAuthorizationError { throw ActivityKitErrors.failure(for: Self.name(failure)) }
        catch { throw ActivityFailure("NATIVE_ERROR", "ActivityKit could not start the activity.") }
    }

    /// Updates the content; without a relevance the activity keeps its score. The timestamp goes along on iOS 17.2.
    func update(_ id: String, state: Attributes.ContentState, relevance: Double?, alert: AlertText?) async throws -> (SystemActivity, Double) {
        let activity = try find(id)
        let score = relevance ?? activity.content.relevanceScore
        let configuration = alert.map {
            AlertConfiguration(title: LocalizedStringResource(stringLiteral: $0.title), body: LocalizedStringResource(stringLiteral: $0.body),
                               sound: .default)
        }
        if #available(iOS 17.2, *), let at = state.timestamp {
            await activity.update(content(state, relevance: score), alertConfiguration: configuration, timestamp: date(at))
        } else {
            await activity.update(content(state, relevance: score), alertConfiguration: configuration)
        }
        return (activity, score)
    }

    /// Ends the activity showing `state`, or without new content when `state` is nil: the system then keeps what it
    /// last published. Without a relevance the activity keeps its score.
    func end(_ id: String, state: Attributes.ContentState?, policy: EndPolicy, relevance: Double?) async throws -> Double {
        let activity = try find(id)
        let score = relevance ?? activity.content.relevanceScore
        let dismissal: ActivityUIDismissalPolicy
        switch policy.kind {
        case "immediate": dismissal = .immediate
        case "after":
            guard let at = policy.at else { throw ActivityFailure("INVALID_INPUT", "A dismissal timestamp is required.") }
            dismissal = .after(date(at))
        default: dismissal = .default
        }
        let final = state.map { content($0, relevance: score) }
        if #available(iOS 17.2, *), let at = state?.timestamp {
            await activity.end(final, dismissalPolicy: dismissal, timestamp: date(at))
        } else {
            await activity.end(final, dismissalPolicy: dismissal)
        }
        return score
    }

    func state(of activity: SystemActivity) -> Attributes.ContentState { activity.content.state }

    func relevance(of activity: SystemActivity) -> Double { activity.content.relevanceScore }

    func lifecycle(of activity: SystemActivity) -> String { Self.name(activity.activityState) }

    /// The contract's name of an ActivityKit state; a state this version does not know is `unknown`.
    nonisolated static func name(_ state: ActivityState) -> String {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), state == .pending { return "pending" }
        #endif
        switch state {
        case .active: return "active"
        case .stale: return "stale"
        case .ended: return "ended"
        case .dismissed: return "dismissed"
        default: return "unknown"
        }
    }

    /// The name of an `ActivityAuthorizationError` case, for `ActivityKitErrors`.
    nonisolated static func name(_ error: ActivityAuthorizationError) -> String {
        switch error {
        case .attributesTooLarge: return "attributesTooLarge"
        case .unsupported: return "unsupported"
        case .denied: return "denied"
        case .globalMaximumExceeded: return "globalMaximumExceeded"
        case .targetMaximumExceeded: return "targetMaximumExceeded"
        case .unsupportedTarget: return "unsupportedTarget"
        case .visibility: return "visibility"
        case .unentitled: return "unentitled"
        default: return String(describing: error)
        }
    }

    private func find(_ id: String) throws -> SystemActivity {
        guard let activity = SystemActivity.activities.first(where: { $0.attributes.instanceID == id }) else {
            throw ActivityFailure("NOT_FOUND", "The activity is no longer available.")
        }
        return activity
    }

    private func content(_ state: Attributes.ContentState, relevance: Double) -> ActivityContent<Attributes.ContentState> {
        ActivityContent(state: state, staleDate: state.staleAt.map(date), relevanceScore: relevance)
    }
}
#endif
