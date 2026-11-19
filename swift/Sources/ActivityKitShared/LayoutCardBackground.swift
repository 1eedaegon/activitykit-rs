import Foundation

/// Who colors the card behind an activity's content with the layout's `background`.
///
/// The system keeps one background tint for an activity, and draws the content in an appearance of its own choice. A
/// light and dark pair given as the tint came as the light color behind content of the dark appearance: on the Lock
/// Screen of the iOS 26.3 simulator at some starts, until the next update, and in the Smart Stack of a paired Apple
/// Watch simulator, whose content is always dark. So the widget draws a pair itself, behind the content and with it,
/// in every activity family, and the system gets a tint only for a color that is the same in both appearances.
extension LayoutDocument {
    /// The background as the one the widget draws or as the system's tint, read from `values` once: a view that needs
    /// both asks here.
    public func cardColors(values: [String: LayoutValue]) -> (drawn: LayoutColorSpec?, tint: LayoutColorSpec?) {
        let color = background(values: values)
        if case .adaptive = color { return (color, nil) }
        return (nil, color)
    }

    /// The background that the widget draws behind the content: a light and dark pair.
    public func drawnBackground(values: [String: LayoutValue]) -> LayoutColorSpec? {
        cardColors(values: values).drawn
    }

    /// The background that is the system's tint: every one that the widget does not draw.
    public func backgroundTint(values: [String: LayoutValue]) -> LayoutColorSpec? {
        cardColors(values: values).tint
    }
}
