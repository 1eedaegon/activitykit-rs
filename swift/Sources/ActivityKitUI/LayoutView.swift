import SwiftUI
import ActivityKitShared

/// Draws one region of a layout activity: the layout's own tree, or the default of an absent island part.
@available(iOS 16.1, *)
public struct LayoutView: View {
    /// Wraps the label of a button node in the host's button, for example `Button(intent:)`, so the package
    /// never names an intent type. Without a builder, or below iOS 17, a button shows its label only.
    public typealias ButtonBuilder = (_ actionId: String, _ label: AnyView) -> AnyView
    /// The view of a `custom` node with its props, bound ones read from the current values, or nil when the host has no
    /// view of that name. Without a builder, or for nil, the node draws nothing.
    public typealias CustomBuilder = (_ name: String, _ props: [String: LayoutValue]) -> AnyView?

    private let node: LayoutRenderNode?
    private let views: LayoutNodeView.Builders

    public init(document: LayoutDocument, values: [String: LayoutValue], region: LayoutRegion, button: ButtonBuilder? = nil,
                custom: CustomBuilder? = nil) {
        node = document.render(region, values: values)
        views = LayoutNodeView.Builders(button: button, custom: custom)
    }

    public var body: some View {
        if let node { LayoutNodeView(node: node, views: views) }
    }
}

/// One resolved node and its subtree.
@available(iOS 16.1, *)
struct LayoutNodeView: View {
    /// What the host draws: buttons and custom views.
    struct Builders {
        let button: LayoutView.ButtonBuilder?
        let custom: LayoutView.CustomBuilder?
    }

    let node: LayoutRenderNode
    let views: Builders

    var body: some View {
        content.layoutStyle(node.style).modifier(LayoutAccessibilityModifier(accessibility: node.accessibility, isLabelOnly: isLabelOnly))
            .modifier(LayoutPresentationModifier(transition: node.transition, isSensitive: node.isSensitive))
    }

    /// A button the host does not build, or below iOS 17, is drawn as its label alone: several views, no control.
    private var isLabelOnly: Bool {
        guard case .button = node.content else { return false }
        if #available(iOS 17.0, *), views.button != nil { return false }
        return true
    }

    @ViewBuilder private var content: some View {
        switch node.content {
        case let .vstack(children, spacing, alignment):
            VStack(alignment: alignment.horizontal, spacing: spacing.map { CGFloat($0) }) { stack(children) }
        case let .hstack(children, spacing, alignment):
            HStack(alignment: alignment.vertical, spacing: spacing.map { CGFloat($0) }) { stack(children) }
        case let .zstack(children, alignment):
            ZStack(alignment: alignment.alignment) { stack(children) }
        case .spacer(let minLength):
            Spacer(minLength: minLength.map { CGFloat($0) })
        case .divider:
            Divider()
        case .text(let text):
            Text(verbatim: text)
        case let .symbol(name, rendering, variableValue):
            Image(systemName: name, variableValue: variableValue).symbolRenderingMode(rendering?.mode)
        case let .image(source, resizable, contentMode):
            LayoutImageView(source: source, resizable: resizable, contentMode: contentMode)
        case let .path(commands, width, height, stroke):
            LayoutPathView(commands: commands, box: CGSize(width: width, height: height), stroke: stroke)
        case let .progress(value, kind):
            if kind == .circular { ProgressView(value: value).progressViewStyle(.circular) }
            else { ProgressView(value: value).progressViewStyle(.linear) }
        case let .gauge(value, range, kind):
            if kind == .circular { Gauge(value: value, in: range) { EmptyView() }.gaugeStyle(.accessoryCircularCapacity) }
            else { Gauge(value: value, in: range) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity) }
        case let .timer(interval, countsDown):
            Text(timerInterval: interval, countsDown: countsDown)
        case let .button(actionId, label):
            wrap(label, as: actionId)
        case let .link(url, label):
            if let url { Link(destination: url) { plain(label) } } else { plain(label) }
        case let .custom(name, props):
            if let view = views.custom?(name, props) { view }
        }
    }

    /// A child is known by its place in the layout, so one that comes or goes is seen as that child, with its transition.
    private func stack(_ children: [LayoutRenderNode]) -> some View {
        ForEach(children, id: \.slot) { LayoutNodeView(node: $0, views: views) }
    }

    /// The label of a button or a link keeps the custom views and has no button of its own.
    private func plain(_ label: LayoutRenderNode) -> LayoutNodeView {
        LayoutNodeView(node: label, views: Builders(button: nil, custom: views.custom))
    }

    private func wrap(_ label: LayoutRenderNode, as actionId: String) -> AnyView {
        let view = AnyView(plain(label))
        if #available(iOS 17.0, *), let button = views.button { return button(actionId, view) }
        return view
    }
}
