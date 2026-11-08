import Foundation

/// How an ended activity leaves the screen: `immediate`, `default`, or `after` a time in epoch milliseconds.
public struct EndPolicy: Codable, Sendable {
    public let kind: String
    public let at: Int64?
    public init(kind: String, at: Int64?) { self.kind = kind; self.at = at }
}

public struct ActivityFailure: Error, Codable, Sendable {
    public let code: String
    public let message: String
    /// `UNSUPPORTED_FEATURE`: the feature and the iOS it needs, such as `"18.0"`.
    public let feature: String?
    public let minimumIos: String?
    /// `SYSTEM_LIMIT`: whose limit, `app` or `device`.
    public let scope: String?
    public init(_ code: String, _ message: String) {
        self.code = code; self.message = message; feature = nil; minimumIos = nil; scope = nil
    }
    private init(_ code: String, _ message: String, feature: String? = nil, minimumIos: String? = nil, scope: String? = nil) {
        self.code = code; self.message = message; self.feature = feature; self.minimumIos = minimumIos; self.scope = scope
    }
    /// A feature that the running iOS does not have yet.
    public static func unsupportedFeature(_ feature: String, minimumIos: String) -> ActivityFailure {
        ActivityFailure("UNSUPPORTED_FEATURE", "\(feature) needs iOS \(minimumIos).", feature: feature, minimumIos: minimumIos)
    }
    /// The app's or the device's limit of running activities; `case` names ActivityKit's error.
    public static func systemLimit(scope: String, case name: String) -> ActivityFailure {
        ActivityFailure("SYSTEM_LIMIT", "The \(scope) limit of Live Activities is reached (\(name)).", scope: scope)
    }
}
