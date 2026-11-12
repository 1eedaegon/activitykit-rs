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
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { LayoutRegionView(context: context, region: .expandedLeading) }
                DynamicIslandExpandedRegion(.trailing) { LayoutRegionView(context: context, region: .expandedTrailing) }
                DynamicIslandExpandedRegion(.center) { LayoutRegionView(context: context, region: .expandedCenter) }
                DynamicIslandExpandedRegion(.bottom) { LayoutRegionView(context: context, region: .expandedBottom) }
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
