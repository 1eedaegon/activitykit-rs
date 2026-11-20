import ActivityKit
import SwiftUI
import WidgetKit
@_exported import ActivityKitShared
@_exported import ActivityKitUI
@_exported import ActivityKitViews
import ActivityKitIntent

/// Draws every activity the app starts with activitykit, on the Lock Screen and in the Dynamic Island, and opens the
/// app with the layout's URL when the person taps one. A widget extension needs only this:
///
/// ```swift
/// import ActivityKitWidget
/// import SwiftUI
/// import WidgetKit
///
/// @main
/// struct Widgets: WidgetBundle {
///     var body: some Widget { ActivityKitLayoutWidget() }
/// }
/// ```
///
/// Its Info.plist sets `ActivityKitLayout` to the integer 2, which the app checks before a start. With
/// `ActivityKitSmallFamily` set to true there, the widget also draws the small family, which the system shows in the
/// Smart Stack of Apple Watch and in CarPlay (iOS 18): a layout's small region, or its compact parts.
@available(iOS 16.1, *)
public struct ActivityKitLayoutWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        Self.withFamilies(activities)
    }

    /// The families beside the medium one that every Live Activity has. A widget states them once, for every activity
    /// it draws, so the extension's Info.plist decides. Without its key the list is empty: the two results of this
    /// function must be one type, so the widget cannot leave the statement out, and states that it has none.
    private static func withFamilies(_ configuration: some WidgetConfiguration) -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return configuration.supplementalActivityFamilies(LayoutSmallFamily.isOn(Bundle.main.infoDictionary ?? [:]) ? [.small] : [])
        }
        return configuration
    }

    private var activities: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityLayoutAttributes.self) { context in
            LayoutLockScreen(context: context)
        } dynamicIsland: { context in
            let document = context.attributes.document
            let island = DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: document.priority(of: .expandedLeading)) {
                    Self.placed(Self.clear(LayoutRegionView(context: context, region: .expandedLeading), of: .leading),
                                below: document.isBelowIfTooWide(.expandedLeading))
                }
                DynamicIslandExpandedRegion(.trailing, priority: document.priority(of: .expandedTrailing)) {
                    Self.placed(Self.clear(LayoutRegionView(context: context, region: .expandedTrailing), of: .trailing),
                                below: document.isBelowIfTooWide(.expandedTrailing))
                }
                DynamicIslandExpandedRegion(.center, priority: document.priority(of: .expandedCenter)) {
                    LayoutRegionView(context: context, region: .expandedCenter)
                }
                DynamicIslandExpandedRegion(.bottom, priority: document.priority(of: .expandedBottom)) {
                    LayoutRegionView(context: context, region: .expandedBottom)
                }
            } compactLeading: {
                LayoutRegionView(context: context, region: .compactLeading)
            } compactTrailing: {
                LayoutRegionView(context: context, region: .compactTrailing)
            } minimal: {
                LayoutRegionView(context: context, region: .minimal)
            }
            // The Dynamic Island is always dark.
            .keylineTint(context.attributes.document.keyline(values: context.state.values).map { Color($0, scheme: .dark) })
            .widgetURL(context.attributes.document.url(values: context.state.values))
            return Self.margined(island, by: document)
        }
    }

    /// What stands in the top outer corner of the expanded island's leading or trailing region is cut there: on the
    /// iOS 26.3 simulator the last letter of a short trailing value lost a tenth of its pixels, a fifth with margins
    /// of 12 and 20 points around the expanded island, and the star of the leading region its top with those margins.
    /// 6 points from the top and from the outer side kept the value whole there and on the iOS 16.2 and 17.2
    /// simulators, where the cut itself was not measured; they add to the margins and padding a layout states.
    private static let expandedCornerClearance: CGFloat = 6

    private static func clear(_ view: some View, of side: Edge.Set) -> some View {
        view.padding([.top, side], expandedCornerClearance)
    }

    /// A leading or trailing region that is too wide for its place beside the camera goes below it, stated on the
    /// region's own content.
    @ViewBuilder private static func placed(_ view: some View, below: Bool) -> some View {
        if below { view.dynamicIsland(verticalPlacement: .belowIfTooWide) } else { view }
    }

    /// The island with the margins the layout states for its presentations; the others keep the system's. Edges of
    /// one length go in one call: one number for every edge is a single call for all of them.
    private static func margined(_ island: DynamicIsland, by document: LayoutDocument) -> DynamicIsland {
        let modes: [(LayoutIslandPresentation, DynamicIslandMode)] = [
            (.expanded, .expanded), (.compactLeading, .compactLeading), (.compactTrailing, .compactTrailing), (.minimal, .minimal)
        ]
        return modes.reduce(island) { island, mode in
            guard let edges = document.margins(for: mode.0) else { return island }
            let sides: [(Edge.Set, Double)] = [(.top, edges.top), (.leading, edges.leading), (.bottom, edges.bottom), (.trailing, edges.trailing)]
            return Set(sides.map(\.1)).sorted().reduce(island) { island, length in
                island.contentMargins(sides.filter { $0.1 == length }.reduce(into: Edge.Set()) { $0.formUnion($1.0) }, length, for: mode.1)
            }
        }
    }
}

@available(iOS 16.1, *)
private struct LayoutLockScreen: View {
    let context: ActivityViewContext<LiveActivityLayoutAttributes>

    var body: some View {
        let host = LayoutActivityHost(context: context)
        let document = context.attributes.document
        // The Lock Screen tree, or what the layout shows where the system asks for the small family.
        let content = LayoutContentView(document: document, values: context.state.values, isStale: host.isStale,
                                        button: host.button, toggle: host.toggle, custom: host.custom)
        Group {
            if #available(iOS 18.0, *) {
                content.modifier(LayoutFamilyCardColor(document: document, values: context.state.values))
            } else {
                content.modifier(LayoutCardColor(document: document, values: context.state.values, isSmallFamily: false))
            }
        }
        .widgetURL(document.url(values: context.state.values))
    }
}

/// Colors the card behind the content with the layout's background: as the system's tint, or, for a light and dark
/// pair, drawn here behind the content and with it (`LayoutDocument.drawnBackground`).
@available(iOS 16.1, *)
private struct LayoutCardColor: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let document: LayoutDocument
    let values: [String: LayoutValue]
    let isSmallFamily: Bool

    func body(content: Content) -> some View {
        let colors = document.cardColors(values: values)
        let drawn = colors.drawn
        return content
            // The content is as wide as its widest node, in the middle of a card that is as wide as the system makes
            // it. On the Lock Screen the widget takes that whole width for it, whatever colors the card: iOS 17 does
            // not find a button or a toggle of content narrower than the card under a tap, and opens the app as for
            // a tap on the activity. A card there is as high as its content. The small family's tile is the
            // system's in both directions, and a color the widget draws fills it.
            .frame(maxWidth: drawn != nil || !isSmallFamily ? .infinity : nil, maxHeight: drawn != nil && isSmallFamily ? .infinity : nil)
            .background { if let drawn { LayoutPairColor(pair: drawn) } }
            .activityBackgroundTint(colors.tint.map { Color($0, scheme: scheme) })
    }
}

/// Reads the family the system asks for, which the environment has from iOS 18.
@available(iOS 18.0, *)
private struct LayoutFamilyCardColor: ViewModifier {
    @Environment(\.activityFamily) private var family
    let document: LayoutDocument
    let values: [String: LayoutValue]

    func body(content: Content) -> some View {
        content.modifier(LayoutCardColor(document: document, values: values, isSmallFamily: family == .small))
    }
}

/// The color of a pair in the appearance that this view is drawn in, read where it is drawn.
@available(iOS 16.1, *)
private struct LayoutPairColor: View {
    @Environment(\.colorScheme) private var scheme
    let pair: LayoutColorSpec

    var body: some View { Color(pair, scheme: scheme) }
}

@available(iOS 16.1, *)
private struct LayoutRegionView: View {
    let context: ActivityViewContext<LiveActivityLayoutAttributes>
    let region: LayoutRegion

    var body: some View {
        let host = LayoutActivityHost(context: context)
        LayoutView(document: context.attributes.document, values: context.state.values, region: region, isStale: host.isStale,
                   button: host.button, toggle: host.toggle, custom: host.custom)
    }
}

/// What a view of the package needs from the activity it draws: its staleness, and the controls and custom views of
/// this app.
@available(iOS 16.1, *)
private struct LayoutActivityHost {
    let context: ActivityViewContext<LiveActivityLayoutAttributes>

    /// Whether the content's stale date has passed, which the system knows from iOS 16.2.
    var isStale: Bool {
        if #available(iOS 16.2, *) { return context.isStale }
        return false
    }

    /// Buttons run `ActivityKitActionIntent` in the app process, from the iOS that runs it (17.2, see the intent);
    /// below it a button is its label.
    var button: LayoutView.ButtonBuilder? {
        guard #available(iOS 17.2, *) else { return nil }
        let activityId = context.attributes.instanceID
        return { actionId, label in
            AnyView(Button(intent: ActivityKitActionIntent(activityId: activityId, actionId: actionId)) { label })
        }
    }

    /// Toggles run the same intent, with the state the person asks for: the opposite of the one shown.
    var toggle: LayoutView.ToggleBuilder? {
        guard #available(iOS 17.2, *) else { return nil }
        let activityId = context.attributes.instanceID
        return { actionId, isOn, label in
            AnyView(Toggle(isOn: isOn, intent: ActivityKitActionIntent(activityId: activityId, actionId: actionId, isOn: !isOn)) { label })
        }
    }

    /// A `custom` node draws the view of its name from the app's `ActivityKitCustomViews`, or nothing.
    var custom: LayoutView.CustomBuilder {
        { name, props in
            ActivityKitCustomViewRegistry.registered?.views[name]?.make(ActivityKitCustomProps(values: props.mapValues(ActivityKitCustomProps.Value.init)))
        }
    }
}

@available(iOS 16.1, *)
private extension ActivityKitCustomProps.Value {
    init(_ value: LayoutValue) {
        switch value {
        case .string(let text): self = .string(text)
        case .number(let number): self = .number(number)
        case .bool(let flag): self = .bool(flag)
        }
    }
}
