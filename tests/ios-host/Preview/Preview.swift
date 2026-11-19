import ActivityKitWidget
import SwiftUI
import UIKit
import WidgetKit

// Draws a layout the way the layout widget draws an activity's content for a family, where no watch and no car is at
// hand: an app can set the family that the system otherwise chooses. The layout is a start request in the
// environment variable `AK_LAYOUT`, the family `AK_FAMILY`, `small` or `medium`: the environment hands JSON on as it
// is, where a launch argument is read as a property list. The frame has about the size of a card in the Smart Stack
// of a watch; its size is for the screenshot, the UI test reads what is drawn.
//
// With `AK_MODE` set to `spoken` it draws the layout's Lock Screen tree instead, on any iOS, and a button that reads
// what the app tells assistive technologies: the labels of the accessibility elements of the window, as VoiceOver
// moves through them. A UI test cannot read that itself: its tree lists hidden elements too.
@main
struct PreviewApp: App {
    var body: some Scene {
        WindowGroup { PreviewScreen() }
    }
}

struct PreviewScreen: View {
    private static let environment = ProcessInfo.processInfo.environment
    private static let request: LayoutRequest? = environment["AK_LAYOUT"]
        .flatMap { try? JSONDecoder().decode(LayoutRequest.self, from: Data($0.utf8)) }
    private static let family = environment["AK_FAMILY"] ?? "medium"
    @State private var spoken = ""

    var body: some View {
        VStack(spacing: 16) {
            if let request = Self.request, Self.environment["AK_MODE"] == "spoken" {
                LayoutView(document: request.document, values: request.snapshot.values, region: .lockScreen)
                    .frame(width: 320)
                Button("Read the elements") { spoken = SpokenLabels.ofKeyWindow().joined(separator: "|") }
                    .accessibilityIdentifier("read")
                Text(spoken.isEmpty ? "not read" : "spoken: \(spoken)").accessibilityIdentifier("spoken")
            } else if let request = Self.request, #available(iOS 18.0, *) {
                LayoutContentView(document: request.document, values: request.snapshot.values)
                    .environment(\.activityFamily, Self.family == "small" ? .small : .medium)
                    .frame(width: 184, height: 76)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 18))
                    .environment(\.colorScheme, .dark)
                Text("family \(Self.family)").accessibilityIdentifier("status")
            } else {
                // Which of the two it lacks, for the test's report.
                Text(Self.environment["AK_LAYOUT"] == nil ? "no layout to draw" : "a layout that is no start request")
                    .accessibilityIdentifier("status")
            }
        }
    }
}

/// The labels of the accessibility elements under a window, in the order of the elements, read through UIKit's
/// accessibility protocols as assistive technologies read them: an element hidden from them is not there, and an
/// element that stands for its children is one label. The test's own button and report are left out.
enum SpokenLabels {
    static func ofKeyWindow() -> [String] {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.filter(\.isKeyWindow).flatMap { labels(of: $0) }
            .filter { !$0.isEmpty && $0 != "Read the elements" && !$0.hasPrefix("spoken: ") && $0 != "not read" }
    }

    private static func labels(of element: NSObject) -> [String] {
        if element.accessibilityElementsHidden { return [] }
        if element.isAccessibilityElement { return [element.accessibilityLabel ?? ""] }
        return children(of: element).flatMap { labels(of: $0) }
    }

    private static func children(of element: NSObject) -> [NSObject] {
        if let elements = element.accessibilityElements as? [NSObject] { return elements }
        let count = element.accessibilityElementCount()
        if count != NSNotFound, count > 0 {
            return (0..<count).compactMap { element.accessibilityElement(at: $0) as? NSObject }
        }
        return (element as? UIView)?.subviews.filter { !$0.isHidden } ?? []
    }
}
