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
    private var watcher: AuthorizationWatcher?

    func authorization() -> AuthorizationReply {
        guard #available(iOS 16.2, *), Platform.supported else { return AuthorizationReply(supported: false, enabled: false, buttons: false) }
        return Self.reply(enabled: ActivityAuthorizationInfo().areActivitiesEnabled)
    }

    private static func reply(enabled: Bool) -> AuthorizationReply {
        var buttons = false
        if #available(iOS 17.0, *) { buttons = true }
        return AuthorizationReply(supported: true, enabled: enabled, buttons: buttons)
    }

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
        let watcher = AuthorizationWatcher(source: EnablementSource(), read: { Self.reply(enabled: $0) },
                                           emit: { events.emit(.authorization($0)) })
        lock.lock(); self.watcher = watcher; lock.unlock()
        watcher.start()
        Task { @MainActor in self.observer.value.start(events) }
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

    func start(_ events: EventSink) {
        guard self.events == nil, #available(iOS 16.2, *) else { return }
        self.events = events
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
