import Foundation

/// Where the PNGs that the app writes with `write_image` live: `activitykit/images` in the App Group container
/// that the widget extension's Info.plist names under `ActivityKitAppGroup`. The app writes them and the widget
/// reads them, so both targets carry that App Group in their entitlements.
public enum LayoutImageFolder {
    public static let infoKey = "ActivityKitAppGroup"
    public static let path = "activitykit/images"

    /// The folder in the group's container, or nil without a group or a container.
    public static func url(group: String?, container: (String) -> URL?) -> URL? {
        guard let group, !group.isEmpty, let root = container(group) else { return nil }
        return root.appendingPathComponent(path, isDirectory: true)
    }

    /// The file of an image `source.file` names, or nil for a name outside the contract.
    public static func file(_ name: String, in folder: URL) -> URL? {
        LayoutRules.isAssetName(name) ? folder.appendingPathComponent(name, isDirectory: false) : nil
    }
}
