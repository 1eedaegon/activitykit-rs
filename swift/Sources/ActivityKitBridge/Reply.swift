import Foundation
#if canImport(ActivityKitShared)
import ActivityKitShared
#endif

/// The reply envelope Rust unwraps: `{"ok":true,"data":…}` or `{"ok":false,"error":{"code","message"}}`.
struct Success<Value: Encodable>: Encodable {
    let ok = true
    let data: Value
}

struct Failure: Encodable {
    let ok = false
    let error: ActivityFailure

    /// Failures keep their code; unreadable requests are INVALID_INPUT and anything else NATIVE_ERROR.
    init(_ error: Error) {
        if let typed = error as? ActivityFailure { self.error = typed }
        else if error is DecodingError { self.error = ActivityFailure("INVALID_INPUT", "Invalid command arguments.") }
        else { self.error = ActivityFailure("NATIVE_ERROR", "The native activity operation failed.") }
    }
}
