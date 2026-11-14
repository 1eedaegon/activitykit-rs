import SwiftUI
import WidgetKit
import ActivityKitShared

/// What a layout activity shows as its content. On the Lock Screen, and wherever the system asks for the medium
/// family, that is the Lock Screen tree. Where it asks for the small family (the Smart Stack of Apple Watch and
/// CarPlay, from iOS 18) it is the layout's small region; a layout without one shows its compact leading and trailing
/// parts side by side there, which is what the system shows when a widget does not draw the family.
///
/// The layout widget draws its activities with this view. An app can draw it too, with `\.activityFamily` set in the
/// environment, to see a layout as a watch or a car gets it.
@available(iOS 16.1, *)
public struct LayoutContentView: View {
    private let document: LayoutDocument
    private let values: [String: LayoutValue]
    private let isStale: Bool
    private let button: LayoutView.ButtonBuilder?
    private let toggle: LayoutView.ToggleBuilder?
    private let custom: LayoutView.CustomBuilder?

    /// The members are those of `LayoutView`, without the region: the family in the environment chooses it.
    public init(document: LayoutDocument, values: [String: LayoutValue], isStale: Bool = false,
                button: LayoutView.ButtonBuilder? = nil, toggle: LayoutView.ToggleBuilder? = nil, custom: LayoutView.CustomBuilder? = nil) {
        self.document = document; self.values = values; self.isStale = isStale
        self.button = button; self.toggle = toggle; self.custom = custom
    }

    public var body: some View {
        if #available(iOS 18.0, *) {
            LayoutFamilyContent(content: self)
        } else {
            region(.lockScreen)
        }
    }

    fileprivate func region(_ region: LayoutRegion) -> LayoutView {
        LayoutView(document: document, values: values, region: region, isStale: isStale, button: button, toggle: toggle, custom: custom)
    }

    /// The regions of the small family in a row, with the room between them: one region is the row.
    fileprivate var small: some View {
        let regions = document.smallFamilyRegions
        return HStack(spacing: 0) {
            ForEach(regions.indices, id: \.self) { index in
                if index > 0 { Spacer(minLength: 0) }
                region(regions[index])
            }
        }
    }
}

/// Reads the family the system asks for, which the environment has from iOS 18.
@available(iOS 18.0, *)
private struct LayoutFamilyContent: View {
    @Environment(\.activityFamily) private var family
    let content: LayoutContentView

    var body: some View {
        switch family {
        case .small: content.small
        case .medium: content.region(.lockScreen)
        @unknown default: content.region(.lockScreen)
        }
    }
}
