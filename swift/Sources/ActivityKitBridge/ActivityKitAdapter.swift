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
@available(iOS 16.1, *)
protocol BridgeActivityAttributes: ActivityAttributes where ContentState: StaleDated {
    var instanceID: String { get }
    var schemaVersion: Int { get }
}
@available(iOS 16.1, *)
extension LiveActivityLayoutAttributes: BridgeActivityAttributes {}

private func date(_ millis: Int64) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }

/// The ActivityKit calls of one attributes type, with the relevance, the alert and the timestamp that ActivityKit takes
/// beside the content. iOS 16.1, ActivityKit's first release, takes the content state alone: it has no stale date and no
/// relevance score, so there the stale date is not given to the system and the relevance is none.
@available(iOS 16.1, *)
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

    /// Starts the activity; the relevance score is the given one, else 0, and none on iOS 16.1. `push` is what the
    /// start asks for. A transient activity needs iOS 18 and a scheduled start iOS 26: before that the start fails here.
    func start(_ attributes: Attributes, state: Attributes.ContentState, relevance: Double?, push: LayoutPush? = nil,
               transient: Bool = false, scheduled: ScheduledStart? = nil) throws -> (SystemActivity, Double?) {
        let pushType = try Self.pushType(push)
        do {
            guard #available(iOS 16.2, *) else {
                return (try requestState(attributes, state: state, pushType: pushType, transient: transient, scheduled: scheduled), nil)
            }
            let score = relevance ?? 0
            return (try request(attributes, content: content(state, relevance: score), pushType: pushType, transient: transient, scheduled: scheduled), score)
        } catch let failure as ActivityFailure { throw failure }
        catch let failure as ActivityAuthorizationError { throw ActivityKitErrors.failure(for: Self.name(failure)) }
        catch {
            if let name = Self.authorizationName(in: error) { throw ActivityKitErrors.failure(for: name) }
            // A push request without the Push Notifications capability or APNs: ActivityKit answers with a permissions
            // error of its own (`SessionCore.PermissionsError` under `com.apple.ActivityKit.ActivityInput`).
            let errors = [error as NSError] + (error as NSError).underlyingErrors.map { $0 as NSError }
            if push != nil, errors.contains(where: { $0.domain.hasSuffix("PermissionsError") }) {
                throw ActivityFailure("CONFIGURATION_REQUIRED",
                                      "ActivityKit refused the push request: the app needs the Push Notifications capability (aps-environment) and APNs (\(error)).")
            }
            throw ActivityFailure("NATIVE_ERROR", "ActivityKit could not start the activity: \(error).")
        }
    }

    /// The request of iOS 16.1, of the content state alone; what came later is refused as above.
    private func requestState(_ attributes: Attributes, state: Attributes.ContentState, pushType: PushType?, transient: Bool,
                              scheduled: ScheduledStart?) throws -> SystemActivity {
        if scheduled != nil { throw ActivityFailure.unsupportedFeature("scheduledStart", minimumIos: "26.0") }
        if transient { throw ActivityFailure.unsupportedFeature("transient", minimumIos: "18.0") }
        return try SystemActivity.request(attributes: attributes, contentState: state, pushType: pushType)
    }

    /// The request ActivityKit has for what the start asks: at a later time with its alert, transient, or the plain one.
    @available(iOS 16.2, *)
    private func request(_ attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: PushType?, transient: Bool,
                         scheduled: ScheduledStart?) throws -> SystemActivity {
        if let scheduled {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                return try SystemActivity.request(attributes: attributes, content: content, pushType: pushType, style: transient ? .transient : .standard,
                                                  alertConfiguration: Self.configuration(scheduled.alert), start: date(scheduled.at))
            }
            #else
            // An app built before the iOS 26 SDK has no such request, whatever the device runs.
            if #available(iOS 26.0, *) {
                throw ActivityFailure("CONFIGURATION_REQUIRED", "A scheduled start needs the app built with the iOS 26 SDK.")
            }
            #endif
            throw ActivityFailure.unsupportedFeature("scheduledStart", minimumIos: "26.0")
        }
        if transient {
            if #available(iOS 18.0, *) {
                return try SystemActivity.request(attributes: attributes, content: content, pushType: pushType, style: .transient)
            }
            throw ActivityFailure.unsupportedFeature("transient", minimumIos: "18.0")
        }
        return try SystemActivity.request(attributes: attributes, content: content, pushType: pushType)
    }

    /// ActivityKit's alert: the title and the body as given, and the sound by its file name or the system's default.
    private static func configuration(_ alert: AlertText) -> AlertConfiguration {
        AlertConfiguration(title: LocalizedStringResource(stringLiteral: alert.title), body: LocalizedStringResource(stringLiteral: alert.body),
                           sound: alert.sound.map { .named($0) } ?? .default)
    }

    /// Updates the content; without a relevance the activity keeps its score. The timestamp goes along on iOS 17.2.
    func update(_ id: String, state: Attributes.ContentState, relevance: Double?, alert: AlertText?) async throws -> (SystemActivity, Double?) {
        let activity = try find(id)
        let configuration = alert.map(Self.configuration)
        guard #available(iOS 16.2, *) else {
            await activity.update(using: state, alertConfiguration: configuration)
            return (activity, nil)
        }
        let score = relevance ?? activity.content.relevanceScore
        if #available(iOS 17.2, *), let at = state.timestamp {
            await activity.update(content(state, relevance: score), alertConfiguration: configuration, timestamp: date(at))
        } else {
            await activity.update(content(state, relevance: score), alertConfiguration: configuration)
        }
        return (activity, score)
    }

    /// Ends the activity showing `state`, or without new content when `state` is nil: the system then keeps what it
    /// last published. Without a relevance the activity keeps its score.
    func end(_ id: String, state: Attributes.ContentState?, policy: EndPolicy, relevance: Double?) async throws -> Double? {
        let activity = try find(id)
        let dismissal: ActivityUIDismissalPolicy
        switch policy.kind {
        case "immediate": dismissal = .immediate
        case "after":
            guard let at = policy.at else { throw ActivityFailure("INVALID_INPUT", "A dismissal timestamp is required.") }
            dismissal = .after(date(at))
        default: dismissal = .default
        }
        guard #available(iOS 16.2, *) else {
            await activity.end(using: state, dismissalPolicy: dismissal)
            return nil
        }
        let score = relevance ?? activity.content.relevanceScore
        let final = state.map { content($0, relevance: score) }
        if #available(iOS 17.2, *), let at = state?.timestamp {
            await activity.end(final, dismissalPolicy: dismissal, timestamp: date(at))
        } else {
            await activity.end(final, dismissalPolicy: dismissal)
        }
        return score
    }

    func state(of activity: SystemActivity) -> Attributes.ContentState { Self.state(of: activity) }

    nonisolated static func state(of activity: SystemActivity) -> Attributes.ContentState {
        guard #available(iOS 16.2, *) else { return activity.contentState }
        return activity.content.state
    }

    func relevance(of activity: SystemActivity) -> Double? {
        guard #available(iOS 16.2, *) else { return nil }
        return activity.content.relevanceScore
    }

    func lifecycle(of activity: SystemActivity) -> String { Self.name(activity.activityState) }

    /// The contract's name of an ActivityKit state; a state this version does not know is `unknown`.
    nonisolated static func name(_ state: ActivityState) -> String {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), state == .pending { return "pending" }
        #endif
        if #available(iOS 16.2, *), state == .stale { return "stale" }
        switch state {
        case .active: return "active"
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

    /// The name of the `ActivityAuthorizationError` inside another error: iOS 16.1 reports a refused start as an error
    /// of `ActivityInput` whose underlying error is the authorization error's, by its domain and code.
    nonisolated static func authorizationName(in error: Error) -> String? {
        let errors = [error as NSError] + (error as NSError).underlyingErrors.map { $0 as NSError }
        guard let found = errors.first(where: { $0.domain == ActivityAuthorizationError.errorDomain }) else { return nil }
        let cases: [ActivityAuthorizationError] = [.attributesTooLarge, .unsupported, .denied, .globalMaximumExceeded, .targetMaximumExceeded,
                                                   .unsupportedTarget, .visibility, .persistenceFailure, .missingProcessIdentifier, .unentitled,
                                                   .malformedActivityIdentifier, .reconnectNotPermitted]
        return cases.first { $0.errorCode == found.code }.map(name)
    }

    /// ActivityKit's push type for what a start asks; a channel needs iOS 18, before that the start fails here.
    static func pushType(_ push: LayoutPush?) throws -> PushType? {
        switch push {
        case nil: return nil
        case .token?: return .token
        case .channel(let id)?:
            if #available(iOS 18, *) { return .channel(id) }
            throw ActivityFailure.unsupportedFeature("pushChannel", minimumIos: "18.0")
        }
    }

    private func find(_ id: String) throws -> SystemActivity {
        guard let activity = SystemActivity.activities.first(where: { $0.attributes.instanceID == id }) else {
            throw ActivityFailure("NOT_FOUND", "The activity is no longer available.")
        }
        return activity
    }

    @available(iOS 16.2, *)
    private func content(_ state: Attributes.ContentState, relevance: Double) -> ActivityContent<Attributes.ContentState> {
        ActivityContent(state: state, staleDate: state.staleAt.map(date), relevanceScore: relevance)
    }
}
#endif
