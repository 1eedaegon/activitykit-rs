#if os(iOS)
import ActivityKit
import Foundation
import UIKit
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif
#if canImport(ActivityKitCore)
import ActivityKitCore
#endif

/// The bridge's system on iOS: ActivityKit, the receipts in Application Support, and the App Group of the widget.
final class ActivityKitSystem: BridgeSystem, @unchecked Sendable {
    private let observer = MainActorBox()
    private let lock = NSLock()
    private var watchers: [AuthorizationWatcher] = []

    func authorization() -> AuthorizationReply {
        guard #available(iOS 16.2, *), Platform.supported else { return AuthorizationReply(supported: false, enabled: false, buttons: false) }
        return Self.reply(enabled: ActivityAuthorizationInfo().areActivitiesEnabled)
    }

    private static func reply(enabled: Bool) -> AuthorizationReply {
        var buttons = false
        if #available(iOS 17.0, *) { buttons = true }
        var frequentPushes = false
        if #available(iOS 16.2, *) { frequentPushes = ActivityAuthorizationInfo().frequentPushesEnabled }
        return AuthorizationReply(supported: true, enabled: enabled, buttons: buttons, frequentPushes: frequentPushes)
    }

    /// The token as APNs takes it: lowercase hex.
    static func hex(_ token: Data) -> String { token.map { String(format: "%02x", $0) }.joined() }

    func imageFolder() throws -> URL {
        guard Platform.supported else { throw Bridge.unsupported }
        return try LayoutWidgetPreflight.imageFolder(plugIns: Bundle.main.builtInPlugInsURL) {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    func activityKey(of id: String) -> String? {
        guard #available(iOS 16.2, *) else { return nil }
        return Activity<LiveActivityLayoutAttributes>.activities.first { $0.attributes.instanceID == id }?.attributes.activityKey
    }

    @MainActor func makeController(presentations: Presentations, events: EventSink, receipts: ReceiptMode) throws -> LayoutActivityController {
        guard #available(iOS 16.2, *), Platform.supported else { throw Bridge.unsupported }
        let store = try FileReceiptStore.applicationStore(mode: receipts)
        let backend = LayoutActivityKitBackend(presentations: presentations, observer: observer.value)
        return LayoutActivityController(backend: backend, store: store)
    }

    func observe(_ events: EventSink) {
        guard #available(iOS 16.2, *), Platform.supported else { return }
        let enablement = AuthorizationWatcher(source: EnablementSource(), read: { Self.reply(enabled: $0) },
                                              emit: { events.emit(.authorization($0)) })
        // A change of the frequent-pushes setting is the whole authorization again, read fresh.
        let frequency = AuthorizationWatcher(source: FrequentPushesSource(),
                                             read: { _ in Self.reply(enabled: ActivityAuthorizationInfo().areActivitiesEnabled) },
                                             emit: { events.emit(.authorization($0)) })
        lock.lock(); watchers = [enablement, frequency]; lock.unlock()
        enablement.start()
        frequency.start()
        Task { @MainActor in self.observer.value.start(events) }
    }

    func watchPushToStart() {
        guard #available(iOS 16.2, *), Platform.supported else { return }
        Task { @MainActor in self.observer.value.watchPushToStart() }
    }
}

/// ActivityKit's changes of the frequent-pushes setting (iOS 16.2).
@available(iOS 16.2, *)
private final class FrequentPushesSource: AuthorizationSource, @unchecked Sendable {
    private let info: ActivityAuthorizationInfo
    let updates: AsyncStream<Bool>

    init() {
        let info = ActivityAuthorizationInfo()
        self.info = info
        updates = AsyncStream { continuation in
            let task = Task {
                for await enabled in info.frequentPushEnablementUpdates { continuation.yield(enabled) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// ActivityKit's changes of the setting. It holds its `ActivityAuthorizationInfo` for the life of the stream.
@available(iOS 16.2, *)
private final class EnablementSource: AuthorizationSource, @unchecked Sendable {
    private let info: ActivityAuthorizationInfo
    let updates: AsyncStream<Bool>

    init() {
        let info = ActivityAuthorizationInfo()
        self.info = info
        updates = AsyncStream { continuation in
            let task = Task {
                for await enabled in info.activityEnablementUpdates { continuation.yield(enabled) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// The observer, made on the main actor when first needed.
private final class MainActorBox: @unchecked Sendable {
    private var made: ActivityObserver?
    @MainActor var value: ActivityObserver {
        if let made { return made }
        let observer = ActivityObserver()
        made = observer
        return observer
    }
}

/// Reports every layout activity that begins while the app runs, and the states of each, to the event handler.
@MainActor
final class ActivityObserver {
    private var events: EventSink?
    private var watched = Set<String>()
    private var pushToStartWanted = false
    private var watchingPushToStart = false

    func start(_ events: EventSink) {
        guard self.events == nil, #available(iOS 16.2, *) else { return }
        self.events = events
        if pushToStartWanted { watchPushToStart() }
        // Those that run already are no news; those that appear later, started by the app, a push or the system, are.
        for activity in Activity<LiveActivityLayoutAttributes>.activities { watch(activity, announce: false) }
        Task {
            for await activity in Activity<LiveActivityLayoutAttributes>.activityUpdates { self.watch(activity, announce: true) }
        }
    }

    /// Reports the states of `activity` from now on, once per activity, and with `announce` that it began.
    @available(iOS 16.2, *)
    func watch(_ activity: Activity<LiveActivityLayoutAttributes>, announce: Bool) {
        let (id, key) = (activity.attributes.instanceID, activity.attributes.activityKey)
        guard let events, activity.attributes.schemaVersion == 2, watched.insert(id).inserted else { return }
        if announce { events.emit(.started(activityId: id, activityKey: key)) }
        Task {
            for await state in activity.activityStateUpdates {
                events.emit(.state(activityId: id, activityKey: key, state: ActivityKitAdapter<LiveActivityLayoutAttributes>.name(state)))
            }
        }
        // The token comes only to an activity that asked for one; content comes for every update, the app's own included.
        // Both loops run off the main actor: a sequence that waits must not hold the actor the calls answer on.
        Task.detached {
            for await token in activity.pushTokenUpdates {
                events.emit(.pushToken(activityId: id, activityKey: key, token: ActivityKitSystem.hex(token)))
            }
        }
        // The content shown when the watch begins is not news: the list gives it. Only content above it is reported.
        let shown = activity.content.state.revision
        Task.detached {
            var reported = shown
            for await content in activity.contentUpdates where content.state.revision > reported {
                reported = content.state.revision
                events.emit(.content(activityId: id, activityKey: key, snapshot: content.state, relevance: content.relevanceScore))
            }
        }
    }

    /// Reports the app's push-to-start token, new or changed, from now on; once, and once the events are known.
    func watchPushToStart() {
        pushToStartWanted = true
        guard let events, !watchingPushToStart, #available(iOS 17.2, *) else { return }
        watchingPushToStart = true
        Task.detached {
            for await token in Activity<LiveActivityLayoutAttributes>.pushToStartTokenUpdates {
                events.emit(.pushToStartToken(token: ActivityKitSystem.hex(token)))
            }
        }
    }
}

/// Whether the device and the OS have Live Activities, read once.
enum Platform {
    static let supported: Bool = {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        let info = ProcessInfo.processInfo
        let version = info.operatingSystemVersion
        // From iOS 17 iPhones and iPads alike have Live Activities, so only iOS 16 needs the device family; reading it
        // then does not wait for the main thread, which may be waiting for this one.
        let family: LiveActivityPlatformSupport.DeviceFamily
        if version.majorVersion >= 17 { family = .pad }
        else {
            switch UIDevice.current.userInterfaceIdiom {
            case .phone: family = .phone
            case .pad: family = .pad
            default: family = .unsupported
            }
        }
        return LiveActivityPlatformSupport.supports(family, version: version, isiOSAppOnMac: info.isiOSAppOnMac)
        #endif
    }()
}
#endif
