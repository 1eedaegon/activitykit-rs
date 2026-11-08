import SwiftUI
import UIKit
import ActivityKitShared

@available(iOS 16.1, *)
extension Color {
    /// A layout color as `scheme` shows it: a system color, one sRGB color, or the light or dark color of a pair.
    /// Resolve a pair with the view's `colorScheme`: the system judges a Live Activity's background tint
    /// when it archives the view, and a dynamic color left it a different appearance than the text.
    public init(_ spec: LayoutColorSpec, scheme: ColorScheme) {
        switch spec {
        case .semantic(let name): self = name.color
        case .fixed(let rgba): self.init(rgba)
        case let .adaptive(light, dark): self.init(scheme == .dark ? dark : light)
        }
    }

    private init(_ rgba: LayoutRGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

@available(iOS 16.1, *)
private extension LayoutSemanticColor {
    var color: Color {
        switch self {
        case .primary: return .primary
        case .secondary: return .secondary
        case .accent: return .accentColor
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .blue: return .blue
        case .indigo: return .indigo
        case .purple: return .purple
        case .pink: return .pink
        case .brown: return .brown
        case .white: return .white
        case .black: return .black
        case .gray: return .gray
        case .clear: return .clear
        }
    }
}

/// An image of the widget extension's asset catalog, or a PNG that the app wrote into the App Group container named by
/// the extension's Info.plist. A missing image draws nothing.
@available(iOS 16.1, *)
struct LayoutImageView: View {
    let source: LayoutImageSource
    let resizable: Bool
    let contentMode: LayoutContentMode?

    /// Read on every render, so an update after the app wrote a new file draws it.
    private var image: Image? {
        switch source {
        case .asset(let name): return UIImage(named: name) == nil ? nil : Image(name)
        case .file(let name):
            guard let file = LayoutImageView.folder.flatMap({ LayoutImageFolder.file(name, in: $0) }),
                  let picture = UIImage(contentsOfFile: file.path) else { return nil }
            return Image(uiImage: picture)
        }
    }

    private static let folder = LayoutImageFolder.url(group: Bundle.main.object(forInfoDictionaryKey: LayoutImageFolder.infoKey) as? String) {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
    }

    var body: some View {
        if let image {
            let sized = resizable ? image.resizable() : image
            if let contentMode { sized.aspectRatio(contentMode: contentMode == .fill ? .fill : .fit) } else { sized }
        }
    }
}

/// Path data in its box, scaled to fit the frame with the box's aspect ratio, filled or stroked.
@available(iOS 16.1, *)
struct LayoutPathView: View {
    let commands: [LayoutPathCommand]
    let box: CGSize
    let stroke: Double?

    var body: some View {
        let shape = LayoutPathShape(commands: commands, box: box)
        Group {
            if let stroke { shape.stroke(lineWidth: stroke) } else { shape }
        }
        .aspectRatio(box, contentMode: .fit)
    }
}

@available(iOS 16.1, *)
struct LayoutPathShape: Shape {
    let commands: [LayoutPathCommand]
    let box: CGSize

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width / box.width, rect.height / box.height)
        let origin = CGPoint(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: origin.x + x * scale, y: origin.y + y * scale) }
        var path = Path()
        for command in commands {
            switch command {
            case let .move(x, y): path.move(to: point(x, y))
            case let .line(x, y): path.addLine(to: point(x, y))
            case let .curve(x1, y1, x2, y2, x, y): path.addCurve(to: point(x, y), control1: point(x1, y1), control2: point(x2, y2))
            case .close: path.closeSubpath()
            }
        }
        return path
    }
}
