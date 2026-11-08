import Foundation

extension EndPolicy {
    /// Any time from 1970 on: the system removes the ended activity at it or four hours after the end, whichever comes
    /// first, and a past time removes it at once.
    public func validate() throws {
        if ["default", "immediate"].contains(kind), at == nil { return }
        guard kind == "after", let at = at, at >= 0 else {
            throw ActivityFailure("INVALID_INPUT", "Invalid dismissal policy.")
        }
    }
}

/// ActivityKit's limit of attributes and content state together, encoded.
public enum PayloadLimit {
    public static let bytes = 4096
}
