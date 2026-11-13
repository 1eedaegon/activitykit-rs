import SwiftUI
import ActivityKitShared

/// Applies a style in the contract's order: font and text members with the content transition, color, tint and button style,
/// padding, frame, background, corner radius, opacity. Absent members leave the inherited values alone.
/// Each member is its own modifier, so the view type grows by one level per member.
@available(iOS 16.1, *)
struct LayoutStyleModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let style: LayoutRenderStyle

    func body(content: Content) -> some View {
        let frame = style.frame
        return content
            .modifier(FontMember(value: style.swiftFont))
            .modifier(WeightMember(value: style.weight?.weight))
            .modifier(DesignMember(value: style.design?.design))
            .modifier(DigitsMember(value: style.monospacedDigit ? true : nil))
            .modifier(LineLimitMember(value: style.lineLimit))
            .modifier(ScaleMember(value: style.minimumScaleFactor))
            .modifier(AlignmentMember(value: style.alignment?.text))
            .modifier(ContentTransitionMember(value: style.contentTransition?.transition))
            .modifier(ForegroundMember(value: color(style.color)))
            .modifier(TintMember(value: color(style.tint)))
            .modifier(ButtonStyleMember(value: style.buttonStyle))
            .modifier(PaddingMember(value: style.padding))
            .modifier(FixedFrameMember(value: frame?.width != nil || frame?.height != nil ? frame : nil))
            .modifier(FlexibleFrameMember(value: [frame?.minWidth, frame?.minHeight, frame?.maxWidth, frame?.maxHeight].contains { $0 != nil } ? frame : nil))
            .modifier(BackgroundMember(value: color(style.background)))
            .modifier(CornerMember(value: style.cornerRadius))
            .modifier(OpacityMember(value: style.opacity))
    }

    private func color(_ spec: LayoutColorSpec?) -> Color? { spec.map { Color($0, scheme: scheme) } }
}

@available(iOS 16.1, *)
extension View {
    func layoutStyle(_ style: LayoutRenderStyle) -> some View {
        modifier(LayoutStyleModifier(style: style))
    }
}

/// One style member: applied when the style has it, otherwise the view stays as it is.
@available(iOS 16.1, *)
private protocol LayoutStyleMember: ViewModifier {
    associatedtype Value
    associatedtype Styled: View
    var value: Value? { get }
    func apply(_ content: Content, _ value: Value) -> Styled
}

@available(iOS 16.1, *)
extension LayoutStyleMember {
    @ViewBuilder func body(content: Content) -> some View {
        if let value { apply(content, value) } else { content }
    }
}

@available(iOS 16.1, *)
private struct FontMember: LayoutStyleMember {
    let value: Font?
    func apply(_ content: Content, _ font: Font) -> some View { content.font(font) }
}
@available(iOS 16.1, *)
private struct WeightMember: LayoutStyleMember {
    let value: Font.Weight?
    func apply(_ content: Content, _ weight: Font.Weight) -> some View { content.fontWeight(weight) }
}
@available(iOS 16.1, *)
private struct DesignMember: LayoutStyleMember {
    let value: Font.Design?
    func apply(_ content: Content, _ design: Font.Design) -> some View { content.fontDesign(design) }
}
@available(iOS 16.1, *)
private struct DigitsMember: LayoutStyleMember {
    let value: Bool?
    func apply(_ content: Content, _ digits: Bool) -> some View { content.monospacedDigit() }
}
@available(iOS 16.1, *)
private struct LineLimitMember: LayoutStyleMember {
    let value: Int?
    func apply(_ content: Content, _ lines: Int) -> some View { content.lineLimit(lines) }
}
@available(iOS 16.1, *)
private struct ScaleMember: LayoutStyleMember {
    let value: Double?
    func apply(_ content: Content, _ factor: Double) -> some View { content.minimumScaleFactor(factor) }
}
@available(iOS 16.1, *)
private struct AlignmentMember: LayoutStyleMember {
    let value: TextAlignment?
    func apply(_ content: Content, _ alignment: TextAlignment) -> some View { content.multilineTextAlignment(alignment) }
}
@available(iOS 16.1, *)
private struct ContentTransitionMember: LayoutStyleMember {
    let value: ContentTransition?
    func apply(_ content: Content, _ transition: ContentTransition) -> some View { content.contentTransition(transition) }
}
@available(iOS 16.1, *)
private struct ForegroundMember: LayoutStyleMember {
    let value: Color?
    func apply(_ content: Content, _ color: Color) -> some View { content.foregroundStyle(color) }
}
@available(iOS 16.1, *)
private struct TintMember: LayoutStyleMember {
    let value: Color?
    func apply(_ content: Content, _ color: Color) -> some View { content.tint(color) }
}
@available(iOS 16.1, *)
private struct ButtonStyleMember: LayoutStyleMember {
    let value: LayoutButtonStyle?
    @ViewBuilder func apply(_ content: Content, _ kind: LayoutButtonStyle) -> some View {
        switch kind {
        case .automatic: content.buttonStyle(.automatic)
        case .bordered: content.buttonStyle(.bordered)
        case .borderedProminent: content.buttonStyle(.borderedProminent)
        case .plain: content.buttonStyle(.plain)
        }
    }
}
@available(iOS 16.1, *)
private struct PaddingMember: LayoutStyleMember {
    let value: LayoutEdges?
    func apply(_ content: Content, _ edges: LayoutEdges) -> some View {
        content.padding(EdgeInsets(top: edges.top, leading: edges.leading, bottom: edges.bottom, trailing: edges.trailing))
    }
}
/// Fixed sizes come first, then the flexible bounds around them.
@available(iOS 16.1, *)
private struct FixedFrameMember: LayoutStyleMember {
    let value: LayoutRenderFrame?
    func apply(_ content: Content, _ frame: LayoutRenderFrame) -> some View {
        content.frame(width: frame.width.map { CGFloat($0) }, height: frame.height.map { CGFloat($0) }, alignment: frame.alignment.alignment)
    }
}
/// A maximum below its minimum is raised to it.
@available(iOS 16.1, *)
private struct FlexibleFrameMember: LayoutStyleMember {
    let value: LayoutRenderFrame?
    func apply(_ content: Content, _ frame: LayoutRenderFrame) -> some View {
        func bound(_ lower: Double?, _ upper: Double?) -> CGFloat? { upper.map { max($0, lower ?? 0) } }
        return content.frame(minWidth: frame.minWidth.map { CGFloat($0) }, maxWidth: bound(frame.minWidth, frame.maxWidth),
                             minHeight: frame.minHeight.map { CGFloat($0) }, maxHeight: bound(frame.minHeight, frame.maxHeight),
                             alignment: frame.alignment.alignment)
    }
}
@available(iOS 16.1, *)
private struct BackgroundMember: LayoutStyleMember {
    let value: Color?
    func apply(_ content: Content, _ color: Color) -> some View { content.background { color } }
}
@available(iOS 16.1, *)
private struct CornerMember: LayoutStyleMember {
    let value: Double?
    func apply(_ content: Content, _ radius: Double) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
@available(iOS 16.1, *)
private struct OpacityMember: LayoutStyleMember {
    let value: Double?
    func apply(_ content: Content, _ opacity: Double) -> some View { content.opacity(opacity) }
}

@available(iOS 16.1, *)
extension LayoutRenderStyle {
    /// The system font, or the extension's font named by `fontFamily`: at a text style's size, scaling with it, or at a
    /// fixed size. A name that the extension does not have draws the system font at that size.
    var swiftFont: Font? {
        guard let family = fontFamily else { return font?.font }
        switch font {
        case .named(let name)?: return .custom(family, size: name.pointSize, relativeTo: name.textStyle)
        case .size(let size)?: return .custom(family, fixedSize: size)
        case nil: return .custom(family, size: LayoutFontName.body.pointSize, relativeTo: .body)
        }
    }
}

@available(iOS 16.1, *)
extension LayoutRenderFont {
    var font: Font {
        switch self {
        case .size(let size): return .system(size: size)
        case .named(let name): return Font.system(name.textStyle)
        }
    }
}

@available(iOS 16.1, *)
extension LayoutFontName {
    var textStyle: Font.TextStyle {
        switch self {
        case .largeTitle: return .largeTitle
        case .title: return .title
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .body: return .body
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption
        case .caption2: return .caption2
        }
    }

    /// The point size of the text style at the default (Large) text size, from Apple's Human Interface Guidelines.
    var pointSize: CGFloat {
        switch self {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        }
    }
}

@available(iOS 16.1, *)
extension LayoutFontWeight {
    var weight: Font.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

@available(iOS 16.1, *)
extension LayoutFontDesign {
    var design: Font.Design {
        switch self {
        case .default: return .default
        case .rounded: return .rounded
        case .serif: return .serif
        case .monospaced: return .monospaced
        }
    }
}

@available(iOS 16.1, *)
extension LayoutHorizontalAlignment {
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

@available(iOS 16.1, *)
extension LayoutVerticalAlignment {
    var vertical: VerticalAlignment {
        switch self {
        case .top: return .top
        case .center: return .center
        case .bottom: return .bottom
        case .firstTextBaseline: return .firstTextBaseline
        }
    }
}

@available(iOS 16.1, *)
extension LayoutAnchor {
    var alignment: Alignment {
        switch self {
        case .center: return .center
        case .leading: return .leading
        case .trailing: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }
}

@available(iOS 16.1, *)
extension LayoutSymbolRendering {
    var mode: SymbolRenderingMode {
        switch self {
        case .monochrome: return .monochrome
        case .hierarchical: return .hierarchical
        case .palette: return .palette
        case .multicolor: return .multicolor
        }
    }
}
