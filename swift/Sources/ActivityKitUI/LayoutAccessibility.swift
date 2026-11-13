import SwiftUI
import ActivityKitShared

/// Tells assistive technologies what a node is: hidden with its subtree, or its label, value and hint. A node drawn
/// as several views (a stack, a custom view, a link or a button drawn as its label alone) becomes one element that
/// stands for them, whose buttons and links stay its actions; otherwise each view inside would take the label.
/// A node without the member keeps what the system reads of it, and so does a sensitive one while the system hides
/// private content.
@available(iOS 16.1, *)
struct LayoutAccessibilityModifier: ViewModifier {
    @Environment(\.redactionReasons) private var redaction
    let accessibility: LayoutRenderAccessibility?
    /// A button drawn without its control, which only the view knows.
    let isLabelOnly: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if let accessibility {
            if accessibility.isSensitive && redaction.contains(.privacy) {
                // The system hides what a sensitive node draws: its label, value and hint are not read out either.
                content
            } else if accessibility.hidden {
                content.accessibilityHidden(true)
            } else if accessibility.combinesChildren || isLabelOnly {
                content.accessibilityElement(children: .combine).spoken(accessibility)
            } else {
                content.spoken(accessibility)
            }
        } else {
            content
        }
    }
}

@available(iOS 16.1, *)
private extension View {
    /// Each member only when the node has it, so that an absent one keeps the system's.
    func spoken(_ accessibility: LayoutRenderAccessibility) -> some View {
        labelled(accessibility.label).valued(accessibility.value).hinted(accessibility.hint)
    }
    @ViewBuilder func labelled(_ text: String?) -> some View {
        if let text { accessibilityLabel(Text(verbatim: text)) } else { self }
    }
    @ViewBuilder func valued(_ text: String?) -> some View {
        if let text { accessibilityValue(Text(verbatim: text)) } else { self }
    }
    @ViewBuilder func hinted(_ text: String?) -> some View {
        if let text { accessibilityHint(Text(verbatim: text)) } else { self }
    }
}
