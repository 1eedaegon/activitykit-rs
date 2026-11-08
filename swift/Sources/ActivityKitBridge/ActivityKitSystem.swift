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

    func authorization() -> AuthorizationReply {
        guard #available(iOS 16.1, *), Platform.supported else { return AuthorizationReply(supported: false, enabled: false, buttons: false) }
        var buttons = false
        if #available(iOS 17.0, *) { buttons = true }
        return AuthorizationReply(supported: true, enabled: ActivityAuthorizationInfo().areActivitiesEnabled, buttons: buttons)
    }

    func imageFolder() throws -> URL {
        guard Platform.supported else { throw Bridge.unsupported }
        return try LayoutWidgetPreflight.imageFolder(plugIns: Bundle.main.builtInPlugInsURL) {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }
    }

    func activityKey(of id: String) -> String? {
        guard #available(iOS 16.1, *) else { return nil }
        return Activity<LiveActivityLayoutAttributes>.activities.first { $0.attributes.instanceID == id }?.attributes.activityKey
    }

    @MainActor func makeController(presentations: Presentations, events: EventSink) throws -> LayoutActivityController {
        guard #available(iOS 16.1, *), Platform.supported else { throw Bridge.unsupported }
        let store = try FileReceiptStore.applicationStore(mode: .full)
        let backend = LayoutActivityKitBackend(presentations: presentations, observer: observer.value)
        return LayoutActivityController(backend: backend, store: store)
    }

    func observe(_ events: EventSink) {
        guard #available(iOS 16.1, *), Platform.supported else { return }
        Task { @MainActor in self.observer.value.start(events) }
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

/// Reports the state of every layout activity and changes of the authorization to the event handler.
@MainActor
final class ActivityObserver {
    private var events: EventSink?
    private var watched = Set<String>()

    func start(_ events: EventSink) {
        guard self.events == nil, #available(iOS 16.1, *) else { return }
        self.events = events
        Task {
            for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates { events.emit(.authorization(enabled: enabled)) }
        }
        for activity in Activity<LiveActivityLayoutAttributes>.activities { watch(activity) }
        Task {
            for await activity in Activity<LiveActivityLayoutAttributes>.activityUpdates { self.watch(activity) }
        }
    }

    /// Reports the states of `activity` from now on, once per activity.
    @available(iOS 16.1, *)
    func watch(_ activity: Activity<LiveActivityLayoutAttributes>) {
        let (id, key) = (activity.attributes.instanceID, activity.attributes.activityKey)
        guard let events, activity.attributes.schemaVersion == 2, watched.insert(id).inserted else { return }
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
