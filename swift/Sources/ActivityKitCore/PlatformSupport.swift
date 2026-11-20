import Foundation

/// What a device that has Live Activities runs of the features that came later, each from the first iOS that runs it.
/// The floors are those of the adapter's refusals (`UNSUPPORTED_FEATURE`) and of the widget's controls.
public struct LiveActivityFeatures: Equatable, Sendable {
    /// A button's and a toggle's intent: 17.2, where the app's App Intents metadata begins it.
    public var buttons = false
    public var pushToStart = false
    public var pushChannels = false
    public var transient = false
    public var scheduledStart = false
    /// The small family, which the system asks of a widget from iOS 18, and which the layout widget draws when its
    /// extension opts in.
    public var smallFamily = false

    public init(buttons: Bool = false) { self.buttons = buttons }

    /// What `version` runs. Whether the widget draws the small family is asked only from iOS 18.
    public init(version: OperatingSystemVersion, widgetDrawsSmallFamily: @autoclosure () -> Bool) {
        func from(_ major: Int, _ minor: Int = 0) -> Bool { (version.majorVersion, version.minorVersion) >= (major, minor) }
        buttons = from(17, 2); pushToStart = from(17, 2)
        pushChannels = from(18); transient = from(18); smallFamily = from(18) && widgetDrawsSmallFamily()
        scheduledStart = from(26)
    }
}

/// OS support is independent from a person's Live Activity settings.
public enum LiveActivityPlatformSupport {
    public enum DeviceFamily { case phone, pad, unsupported }

    public static func supports(_ family: DeviceFamily, version: OperatingSystemVersion, isiOSAppOnMac: Bool = false) -> Bool {
        guard !isiOSAppOnMac else { return false }
        switch family {
        // ActivityKit's first release, 16.1, which has no stale date and no relevance score.
        case .phone: return version.majorVersion > 16 || (version.majorVersion == 16 && version.minorVersion >= 1)
        case .pad: return version.majorVersion >= 17
        case .unsupported: return false
        }
    }
}
