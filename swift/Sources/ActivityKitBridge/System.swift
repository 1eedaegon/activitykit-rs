import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif
#if canImport(ActivityKitCore)
import ActivityKitCore
#endif

/// What `ak_authorization` answers.
struct AuthorizationReply: Codable, Equatable, Sendable {
    /// An iPhone with iOS 16.2 or later, or an iPad with iPadOS 17 or later; not an iOS app on a Mac.
    let supported: Bool
    /// Supported, and Live Activities are on for this app.
    let enabled: Bool
    /// Supported, and iOS 17 or later, where buttons run their intent.
    let buttons: Bool
    /// Supported, and the person allows frequent pushes for the app (iOS 16.2).
    let frequentPushes: Bool
    private enum CodingKeys: String, CodingKey { case supported, enabled, buttons, frequentPushes }
    init(supported: Bool, enabled: Bool, buttons: Bool, frequentPushes: Bool = false) {
        self.supported = supported; self.enabled = enabled; self.buttons = buttons; self.frequentPushes = frequentPushes
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        supported = try container.decode(Bool.self, forKey: .supported)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        buttons = try container.decode(Bool.self, forKey: .buttons)
        frequentPushes = try container.decodeIfPresent(Bool.self, forKey: .frequentPushes) ?? false
    }
}

/// What the bridge drives: ActivityKit on iOS (`ActivityKitSystem`), nothing elsewhere, a fake in the host tests.
protocol BridgeSystem: AnyObject, Sendable {
    /// Read on any thread.
    func authorization() -> AuthorizationReply
    /// The folder of the images the app writes. Any thread.
    func imageFolder() throws -> URL
    /// The activity key of a tapped activity while the system lists it. Any thread.
    func activityKey(of id: String) -> String?
    /// The controller of layout activities, made once, on the first call, with receipts in the mode of the settings.
    @MainActor func makeController(presentations: Presentations, events: EventSink, receipts: ReceiptMode) throws -> LayoutActivityController
    /// Starts reporting state and authorization changes to `events`; called once.
    func observe(_ events: EventSink)
    /// Starts reporting the app's push-to-start token (iOS 17.2) to the events of `observe`, once.
    func watchPushToStart()
}

extension BridgeSystem {
    func watchPushToStart() {}
}

/// The system the bridge uses; tests install their own before they call.
enum Systems {
    private static let lock = NSLock()
    private static var installed: BridgeSystem?

    static var current: BridgeSystem {
        lock.lock(); defer { lock.unlock() }
        if let installed { return installed }
        #if os(iOS)
        let made: BridgeSystem = ActivityKitSystem()
        #else
        let made: BridgeSystem = UnsupportedSystem()
        #endif
        installed = made
        return made
    }

    static func install(_ system: BridgeSystem) {
        lock.lock(); defer { lock.unlock() }
        installed = system
    }
}

/// A platform without Live Activities: every call is UNSUPPORTED_PLATFORM.
final class UnsupportedSystem: BridgeSystem {
    func authorization() -> AuthorizationReply { AuthorizationReply(supported: false, enabled: false, buttons: false) }
    func imageFolder() throws -> URL { throw Bridge.unsupported }
    func activityKey(of id: String) -> String? { nil }
    @MainActor func makeController(presentations: Presentations, events: EventSink, receipts: ReceiptMode) throws -> LayoutActivityController {
        throw Bridge.unsupported
    }
    func observe(_ events: EventSink) {}
}

/// What ActivityKit takes beside the contract request, held while the controller runs that request. The backend reads
/// it when it calls ActivityKit; the lifecycle in between stays as it is.
@MainActor
final class Presentations {
    struct Update: Equatable {
        let relevance: Double?
        let alert: AlertText?
    }

    /// The relevance of a start, and what it asks ActivityKit for: a push token or channel, a transient activity,
    /// a start at a later time.
    struct Start: Equatable {
        let relevance: Double?
        let push: LayoutPush?
        let transient: Bool
        let scheduled: ScheduledStart?
    }

    private var starts: [String: Start] = [:]
    private var updates: [String: Update] = [:]
    private var ends: [String: Double] = [:]

    func expectStart(key: String, relevance: Double?, push: LayoutPush? = nil, transient: Bool = false, scheduled: ScheduledStart? = nil) {
        starts[key] = Start(relevance: relevance, push: push, transient: transient, scheduled: scheduled)
    }
    func forgetStart(key: String) { starts[key] = nil }
    /// The relevance and the push of the start with this activity key.
    func start(key: String) -> Start? { starts[key] }

    func expectUpdate(id: String, revision: Int64, relevance: Double?, alert: AlertText?) {
        updates[Self.key(id, revision)] = Update(relevance: relevance, alert: alert)
    }
    func forgetUpdate(id: String, revision: Int64) { updates[Self.key(id, revision)] = nil }
    /// The relevance and the alert of the update of this activity to this revision.
    func update(id: String, revision: Int64) -> Update? { updates[Self.key(id, revision)] }

    func expectEnd(id: String, relevance: Double?) { ends[id] = relevance }
    func forgetEnd(id: String) { ends[id] = nil }
    /// The relevance of the end of this activity.
    func end(id: String) -> Double? { ends[id] }

    private static func key(_ id: String, _ revision: Int64) -> String { "\(revision) \(id)" }
}
