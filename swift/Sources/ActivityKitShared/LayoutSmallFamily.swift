import Foundation

/// The small activity family: what the system asks a widget for in the Smart Stack of Apple Watch and in CarPlay,
/// from iOS 18. A widget declares its families once, for every activity it draws, so the layout widget asks for this
/// one only when its extension's Info.plist sets `ActivityKitSmallFamily` to true. Without the key the system shows
/// the compact parts of the Dynamic Island there.
public enum LayoutSmallFamily {
    public static let infoKey = "ActivityKitSmallFamily"

    /// Whether an Info.plist opts in: only the Boolean true does. Text such as `YES`, which a build setting expands
    /// to, and a number do not, so that the widget and the app, which both read the key, cannot disagree on one.
    public static func isOn(_ info: [String: Any]) -> Bool {
        guard let flag = info[infoKey] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return false }
        return flag.boolValue
    }
}

extension LayoutDocument {
    /// What a widget that draws the small family shows for this layout: the small region, or, for a layout without
    /// one, the compact leading and trailing parts side by side, which is what the system shows without the family.
    public var smallFamilyRegions: [LayoutRegion] {
        layout.small == nil ? [.compactLeading, .compactTrailing] : [.small]
    }

    /// What the widget leaves out of this layout: `layout.custom.<name>` for each custom view that `registered` lacks,
    /// and `layout.small` for a small region when the widget does not draw the small family.
    public func degradedFeatures(registered: Set<String>?, drawsSmall: Bool) -> [String] {
        unknownCustomViews(registered: registered) + (layout.small == nil || drawsSmall ? [] : ["layout.small"])
    }
}
