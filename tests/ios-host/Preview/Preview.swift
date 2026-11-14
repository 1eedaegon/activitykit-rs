import ActivityKitWidget
import SwiftUI
import WidgetKit

// Draws a layout the way the layout widget draws an activity's content for a family, where no watch and no car is at
// hand: an app can set the family that the system otherwise chooses. The layout is a start request in the launch
// argument `-layout`, the family `-family small` or `medium`. The frame has about the size of a card in the Smart
// Stack of a watch; its size is for the screenshot, the UI test reads what is drawn.
@main
struct PreviewApp: App {
    var body: some Scene {
        WindowGroup { PreviewScreen() }
    }
}

struct PreviewScreen: View {
    private static let request: LayoutRequest? = UserDefaults.standard.string(forKey: "layout")
        .flatMap { try? JSONDecoder().decode(LayoutRequest.self, from: Data($0.utf8)) }
    private static let family = UserDefaults.standard.string(forKey: "family") ?? "medium"

    var body: some View {
        VStack(spacing: 16) {
            if let request = Self.request, #available(iOS 18.0, *) {
                LayoutContentView(document: request.document, values: request.snapshot.values)
                    .environment(\.activityFamily, Self.family == "small" ? .small : .medium)
                    .frame(width: 184, height: 76)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
                    .environment(\.colorScheme, .dark)
                Text("family \(Self.family)").accessibilityIdentifier("status")
            } else {
                Text("no layout to draw").accessibilityIdentifier("status")
            }
        }
    }
}
