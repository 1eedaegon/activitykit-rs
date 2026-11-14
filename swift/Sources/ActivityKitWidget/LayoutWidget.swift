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
                    Self.placed(LayoutRegionView(context: context, region: .expandedLeading), below: document.isBelowIfTooWide(.expandedLeading))
                }
                DynamicIslandExpandedRegion(.trailing, priority: document.priority(of: .expandedTrailing)) {
                    Self.placed(LayoutRegionView(context: context, region: .expandedTrailing), below: document.isBelowIfTooWide(.expandedTrailing))
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
    @Environment(\.colorScheme) private var scheme
    let context: ActivityViewContext<LiveActivityLayoutAttributes>

    var body: some View {
        let host = LayoutActivityHost(context: context)
        // The Lock Screen tree, or what the layout shows where the system asks for the small family.
        LayoutContentView(document: context.attributes.document, values: context.state.values, isStale: host.isStale,
                          button: host.button, toggle: host.toggle, custom: host.custom)
            .activityBackgroundTint(context.attributes.document.background(values: context.state.values).map { Color($0, scheme: scheme) })
            .widgetURL(context.attributes.document.url(values: context.state.values))
    }
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

    /// Buttons run `ActivityKitActionIntent` in the app process.
    var button: LayoutView.ButtonBuilder? {
        guard #available(iOS 17.0, *) else { return nil }
        let activityId = context.attributes.instanceID
        return { actionId, label in
            AnyView(Button(intent: ActivityKitActionIntent(activityId: activityId, actionId: actionId)) { label })
        }
    }

    /// Toggles run the same intent, with the state the person asks for: the opposite of the one shown.
    var toggle: LayoutView.ToggleBuilder? {
        guard #available(iOS 17.0, *) else { return nil }
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
