import Foundation

/// OS support is independent from a person's Live Activity settings.
public enum LiveActivityPlatformSupport {
    public enum DeviceFamily { case phone, pad, unsupported }

    public static func supports(_ family: DeviceFamily, version: OperatingSystemVersion, isiOSAppOnMac: Bool = false) -> Bool {
        guard !isiOSAppOnMac else { return false }
        switch family {
        case .phone: return version.majorVersion > 16 || (version.majorVersion == 16 && version.minorVersion >= 1)
        case .pad: return version.majorVersion >= 17
        case .unsupported: return false
        }
    }
}
