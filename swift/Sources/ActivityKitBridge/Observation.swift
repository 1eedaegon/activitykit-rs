import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

/// Where changes of the Live Activities setting come from: ActivityKit's `activityEnablementUpdates` on iOS.
protocol AuthorizationSource: AnyObject, Sendable {
    var updates: AsyncStream<Bool> { get }
}

/// Reports each change of the setting as the whole authorization. It holds its source for as long as it lives: the
/// stream belongs to the source, and a source that nothing holds may end it.
final class AuthorizationWatcher: @unchecked Sendable {
    private let source: AuthorizationSource
    private let read: @Sendable (Bool) -> AuthorizationReply
    private let emit: @Sendable (AuthorizationReply) -> Void
    private var task: Task<Void, Never>?

    init(source: AuthorizationSource, read: @escaping @Sendable (Bool) -> AuthorizationReply,
         emit: @escaping @Sendable (AuthorizationReply) -> Void) {
        self.source = source; self.read = read; self.emit = emit
    }

    deinit { task?.cancel() }

    func start() {
        let (updates, read, emit) = (source.updates, read, emit)
        task = Task { for await enabled in updates { emit(read(enabled)) } }
    }
}

/// `ActivityAuthorizationError` by the name of its case, as the iOS 26.2 SDK has them, to the contract's failure. The
/// message names the case.
enum ActivityKitErrors {
    static func failure(for name: String) -> ActivityFailure {
        switch name {
        case "attributesTooLarge": return ActivityFailure("PAYLOAD_TOO_LARGE", "ActivityKit rejected the payload size (attributesTooLarge).")
        case "unsupported": return ActivityFailure("UNSUPPORTED_PLATFORM", "The device has no Live Activities (unsupported).")
        case "denied": return ActivityFailure("PERMISSION_DENIED", "Live Activities are turned off for the app in Settings (denied).")
        case "globalMaximumExceeded": return .systemLimit(scope: "device", case: name)
        case "targetMaximumExceeded": return .systemLimit(scope: "app", case: name)
        case "unsupportedTarget":
            return ActivityFailure("CONFIGURATION_REQUIRED", "This target cannot start Live Activities, check NSSupportsLiveActivities (unsupportedTarget).")
        case "visibility": return ActivityFailure("NOT_FOREGROUND", "ActivityKit refused a start outside the foreground (visibility).")
        case "unentitled": return ActivityFailure("CONFIGURATION_REQUIRED", "The app lacks the entitlement or Info.plist key (unentitled).")
        default: return ActivityFailure("NATIVE_ERROR", "ActivityKit could not start the activity (\(name)).")
        }
    }
}
