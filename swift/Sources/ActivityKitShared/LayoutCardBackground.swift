import Foundation

/// Who colors the card behind an activity's content with the layout's `background`.
///
/// The system keeps one background tint for an activity, and draws the content in an appearance of its own choice. A
/// light and dark pair given as the tint came, at some starts on the iOS 26.3 simulator, as the light color behind
/// content of the dark appearance, and stayed until the next update. So the widget draws a pair itself, behind the
/// content and with it, where it draws the medium family: the Lock Screen and the banner. In the small family (Apple
/// Watch, CarPlay) a pair is still the tint: nobody has seen there whether a color drawn by the content fills the
/// tile.
extension LayoutDocument {
    /// The background that the widget draws behind the content: a pair, outside the small family.
    public func drawnBackground(values: [String: LayoutValue], isSmallFamily: Bool) -> LayoutColorSpec? {
        guard !isSmallFamily, let color = background(values: values), case .adaptive = color else { return nil }
        return color
    }

    /// The background that is the system's tint: every one that the widget does not draw.
    public func backgroundTint(values: [String: LayoutValue], isSmallFamily: Bool) -> LayoutColorSpec? {
        drawnBackground(values: values, isSmallFamily: isSmallFamily) == nil ? background(values: values) : nil
    }
}
