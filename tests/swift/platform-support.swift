import Foundation

extension LifecycleTests {
    @MainActor static func testPlatformSupport() {
        let cases: [(LiveActivityPlatformSupport.DeviceFamily, Int, Int, Bool)] = [
            (.phone, 16, 0, false), (.phone, 16, 1, true), (.phone, 16, 2, true),
            (.phone, 15, 7, false), (.phone, 27, 2, true),
            (.pad, 16, 1, false), (.pad, 16, 7, false), (.pad, 17, 0, true),
            (.pad, 27, 2, true), (.unsupported, 27, 2, false)
        ]
        for (family, major, minor, supported) in cases {
            expect(LiveActivityPlatformSupport.supports(family,
                version: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0)) == supported,
                "\(family) \(major).\(minor) support must be \(supported)")
        }
        expect(!LiveActivityPlatformSupport.supports(.pad,
            version: OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0), isiOSAppOnMac: true),
            "iOS compatibility app on Mac is not the iPhone/iPad backend")
    }
}
