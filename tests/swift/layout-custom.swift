import Foundation

/// A registry under an Objective-C name, as LiveActivityCustomViews.swift declares `ActivityKitCustomViews`.
@objc(ActivityKitCustomViewsTest)
final class TestCustomViewRegistry: NSObject {
    @objc class var viewNames: [String] { ["ring", "bar"] }
}

/// A class of that kind of name without the names.
@objc(ActivityKitCustomViewsWithoutNames)
final class RegistryWithoutNames: NSObject {}

extension LifecycleTests {
    @MainActor static func testLayoutCustomizations() throws {
        try testCustomNodes()
        try testFontFamilyAndFileImages()
        try testImageFolder()
    }

    // AK-CUSTOM-2, AK-CUSTOM-3, AK-RENDER-11
    @MainActor private static func testCustomNodes() throws {
        let ring = try layoutDocument(#"{"type":"vstack","children":[{"type":"custom","name":"ring","props":{"level":{"bind":"bowl"},"width":3,"#
            + #""label":"Bowl","on":true}},{"type":"custom","name":"bare","if":"on"}]}"#)
        func shown(_ bowl: Double) -> [LayoutRenderContent] { children(ring.render(.lockScreen, values: ["bowl": .number(bowl), "on": .bool(true)])).map(\.content) }
        let props: [String: LayoutValue] = ["level": .number(0.25), "width": .number(3), "label": .string("Bowl"), "on": .bool(true)]
        expect(shown(0.25) == [.custom(name: "ring", props: props), .custom(name: "bare", props: [:])], "custom nodes carry literal and bound props")
        expect(shown(0.75).first == .custom(name: "ring", props: props.merging(["level": .number(0.75)]) { $1 }), "a bound prop reads the values of each render")
        expect(children(ring.render(.lockScreen, values: ["on": .bool(false)])).map(\.content) == [.custom(name: "ring", props: props.filter { $0.key != "level" })],
               "a condition hides a custom node, and a bound prop without a value is absent")

        let island = try layoutDocument(#"{"type":"button","actionId":"a","child":{"type":"custom","name":"paw"}}"#,
                                        layout: #","island":{"minimal":{"type":"custom","name":"dot"},"compactLeading":{"type":"custom","name":"paw"}}"#)
        expect(island.customViewNames == ["paw", "dot"], "custom view names in document order, region by region, each once")
        expect(island.unknownCustomViews(registered: ["paw", "ring"]) == ["layout.custom.dot"], "a name without a registered view is reported")
        expect(island.unknownCustomViews(registered: nil) == ["layout.custom.paw", "layout.custom.dot"], "without a registry every name is reported")
        let plain = try layoutDocument(#"{"type":"text","value":"a"}"#)
        expect(plain.unknownCustomViews(registered: nil).isEmpty, "a layout without custom nodes reports none")

        expect(CustomViewCatalog.names(className: "ActivityKitCustomViewsTest") == ["ring", "bar"], "the catalog reads the registry's names")
        expect(CustomViewCatalog.names(className: "ActivityKitCustomViewsWithoutNames") == nil, "a class without names is no registry")
        expect(CustomViewCatalog.names(className: "ActivityKitCustomViewsMissing") == nil && CustomViewCatalog.names() == nil,
               "no class, no registry")

        let request = try layoutRequest(layoutJSON(lockScreen: #"{"type":"custom","name":"ring"}"#))
        let attributes = try LiveActivityLayoutAttributes(request: request, instanceID: "la-ios-layout-custom")
        let activity = LayoutActivity(id: "la-ios-layout-custom", attributes: attributes, snapshot: request.snapshot, state: "active",
                                      degradedFeatures: attributes.document.unknownCustomViews(registered: []))
        expect(activity.record.degradedFeatures == ["layout.custom.ring"], "the record reports the unknown custom view")
        expect(activity.with(snapshot: request.snapshot, state: "ended").record.degradedFeatures == ["layout.custom.ring"], "an update or end keeps the report")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(activity.record)) as? [String: Any]
        expect(encoded?["degradedFeatures"] as? [String] == ["layout.custom.ring"], "the record encodes the report")
    }

    // AK-FONT-1, AK-RENDER-5
    @MainActor private static func testFontFamilyAndFileImages() throws {
        let styled = try layoutDocument(#"{"type":"hstack","children":[{"type":"text","value":"a","style":"face"},"#
            + #"{"type":"image","source":{"file":"badge.png"},"resizable":true,"contentMode":"fill"}]}"#,
            styles: #"{"face":{"fontFamily":"Pacifico","size":{"bind":"points"},"weight":"bold"},"plain":{"font":"body"}}"#)
        let style = styled.style("face", values: ["points": .number(24)])
        expect(style.fontFamily == "Pacifico" && style.font == .size(24) && style.weight == .bold, "a font family with a bound size and a weight")
        expect(styled.style("plain").fontFamily == nil && LayoutRenderStyle.plain.fontFamily == nil, "no font family without the member")
        expect(children(styled.render(.lockScreen, values: ["points": .number(24)])).last?.content
               == .image(source: .file("badge.png"), resizable: true, contentMode: .fill), "an image drawn from a file")
        expect(LayoutImageSource.file("a.png").name == "a.png" && LayoutImageSource.asset("logo").name == "logo", "the name of each source")
    }

    // AK-IMAGE-4, AK-IMAGE-5
    @MainActor private static func testImageFolder() throws {
        let root = URL(fileURLWithPath: "/container", isDirectory: true)
        expect(LayoutImageFolder.url(group: nil) { _ in root } == nil && LayoutImageFolder.url(group: "") { _ in root } == nil, "no group, no folder")
        expect(LayoutImageFolder.url(group: "group.a") { _ in nil } == nil, "no container, no folder")
        let folder = LayoutImageFolder.url(group: "group.a") { $0 == "group.a" ? root : nil }
        expect(folder?.path == "/container/activitykit/images", "the folder in the group's container")
        expect(folder.flatMap { LayoutImageFolder.file("badge.png", in: $0) }?.path == "/container/activitykit/images/badge.png", "a file in it")
        for name in ["../secret", "a/b", ".hidden", "", String(repeating: "a", count: 65)] {
            expect(folder.flatMap { LayoutImageFolder.file(name, in: $0) } == nil, "no file outside the contract: \(name)")
        }

        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let plugIns = base.appendingPathComponent("PlugIns", isDirectory: true)
        func appex(_ name: String, _ info: [String: Any]) throws {
            let bundle = plugIns.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundle.appendingPathComponent("Info.plist"))
        }
        let container = base.appendingPathComponent("Group", isDirectory: true)
        func resolve(_ group: String) -> URL? { group == "group.app" ? container : nil }
        try appex("Other.appex", ["ActivityKitAppGroup": "group.app"])
        try appex("Widget.appex", ["ActivityKitLayout": 2])
        let failure = { (code: String, label: String) in
            do { _ = try LayoutWidgetPreflight.imageFolder(plugIns: plugIns, container: resolve); expect(false, label) }
            catch let error as ActivityFailure { expect(error.code == code, "\(label): \(error.code)") }
            catch { expect(false, "\(label): \(error)") }
        }
        failure("CONFIGURATION_REQUIRED", "only the layout widget's App Group counts")
        try appex("Widget.appex", ["ActivityKitLayout": 2, "ActivityKitAppGroup": "group.other"])
        failure("CONFIGURATION_REQUIRED", "a group without a container")
        try appex("Widget.appex", ["ActivityKitLayout": 2, "ActivityKitAppGroup": "group.app"])
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data().write(to: container.appendingPathComponent("activitykit"))
        failure("NATIVE_ERROR", "a file where the folder goes")
        try FileManager.default.removeItem(at: container.appendingPathComponent("activitykit"))
        let images = try LayoutWidgetPreflight.imageFolder(plugIns: plugIns, container: resolve)
        var isFolder: ObjCBool = false
        expect(images.path == container.appendingPathComponent("activitykit/images").path
               && FileManager.default.fileExists(atPath: images.path, isDirectory: &isFolder) && isFolder.boolValue, "the folder is created")
        let again = try LayoutWidgetPreflight.imageFolder(plugIns: plugIns, container: resolve)
        expect(again == images, "and found again")
        do { _ = try LayoutWidgetPreflight.imageFolder(plugIns: nil, container: resolve); expect(false, "no plug-ins") }
        catch let error as ActivityFailure { expect(error.code == "CONFIGURATION_REQUIRED", "no plug-ins folder") }
    }
}
