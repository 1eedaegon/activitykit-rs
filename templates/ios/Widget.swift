import ActivityKitWidget
import SwiftUI
import WidgetKit

// The widget extension's only Swift file. Link the extension to the `ActivityKitWidget` product of activitykit's
// `swift` package, and set `ActivityKitLayout` to the integer 2 in its Info.plist (templates/ios/Widget-Info.plist).
@main
struct Widgets: WidgetBundle {
    var body: some Widget {
        ActivityKitLayoutWidget()
    }
}
