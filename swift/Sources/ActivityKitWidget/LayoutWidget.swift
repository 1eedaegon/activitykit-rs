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
/// Its Info.plist sets `ActivityKitLayout` to the integer 2, which the app checks before a start.
@available(iOS 16.1, *)
public struct ActivityKitLayoutWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
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
        LayoutRegionView(context: context, region: .lockScreen)
            .activityBackgroundTint(context.attributes.document.background(values: context.state.values).map { Color($0, scheme: scheme) })
            .widgetURL(context.attributes.document.url(values: context.state.values))
    }
}

@available(iOS 16.1, *)
private struct LayoutRegionView: View {
    let context: ActivityViewContext<LiveActivityLayoutAttributes>
    let region: LayoutRegion

    var body: some View {
        LayoutView(document: context.attributes.document, values: context.state.values, region: region, button: button, custom: custom)
    }

    /// Buttons run `ActivityKitActionIntent` in the app process.
    private var button: LayoutView.ButtonBuilder? {
        guard #available(iOS 17.0, *) else { return nil }
        let activityId = context.attributes.instanceID
        return { actionId, label in
            AnyView(Button(intent: ActivityKitActionIntent(activityId: activityId, actionId: actionId)) { label })
        }
    }

    /// A `custom` node draws the view of its name from the app's `ActivityKitCustomViews`, or nothing.
    private var custom: LayoutView.CustomBuilder {
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
