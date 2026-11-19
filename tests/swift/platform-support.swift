import Foundation

extension LifecycleTests {
    // AK-AUTH-8
    /// Each feature that came after Live Activities from the first iOS that runs it; the small family also only with
    /// a widget extension that draws it.
    @MainActor static func testLaterFeatures() {
        func features(_ major: Int, _ minor: Int, widget: Bool = true) -> LiveActivityFeatures {
            LiveActivityFeatures(version: OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: 0), widgetDrawsSmallFamily: widget)
        }
        func on(_ found: LiveActivityFeatures) -> [String] {
            [("buttons", found.buttons), ("pushToStart", found.pushToStart), ("pushChannels", found.pushChannels),
             ("transient", found.transient), ("scheduledStart", found.scheduledStart), ("smallFamily", found.smallFamily)].filter(\.1).map(\.0)
        }
        let all = ["buttons", "pushToStart", "pushChannels", "transient", "scheduledStart", "smallFamily"]
        let cases: [(Int, Int, [String])] = [
            (16, 2, []), (17, 0, []), (17, 1, []), (17, 2, Array(all.prefix(2))), (17, 4, Array(all.prefix(2))),
            (18, 0, ["buttons", "pushToStart", "pushChannels", "transient", "smallFamily"]), (25, 9, ["buttons", "pushToStart", "pushChannels", "transient", "smallFamily"]),
            (26, 0, all), (27, 2, all)
        ]
        for (major, minor, expected) in cases {
            expect(on(features(major, minor)) == expected, "iOS \(major).\(minor) runs \(expected), got \(on(features(major, minor)))")
        }
        expect(!features(26, 0, widget: false).smallFamily && features(26, 0, widget: false).scheduledStart,
               "without a widget that draws it there is no small family")
        expect(on(LiveActivityFeatures()) == [], "a device without Live Activities runs none of them")
        var asked = 0
        func widget() -> Bool { asked += 1; return true }
        _ = LiveActivityFeatures(version: OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0), widgetDrawsSmallFamily: widget())
        expect(asked == 0, "below iOS 18 the widget extension is not read")
        _ = LiveActivityFeatures(version: OperatingSystemVersion(majorVersion: 18, minorVersion: 0, patchVersion: 0), widgetDrawsSmallFamily: widget())
        expect(asked == 1, "from iOS 18 it is")
    }

    // AK-PLATFORM-1, AK-START-7
    @MainActor static func testPlatformSupport() {
        let cases: [(LiveActivityPlatformSupport.DeviceFamily, Int, Int, Bool)] = [
            (.phone, 16, 0, false), (.phone, 16, 1, false), (.phone, 16, 2, true),
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
