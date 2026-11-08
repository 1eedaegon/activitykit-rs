import ActivityKitViews
import SwiftUI

// Views for `custom` layout nodes. Compile this file into the widget extension, which draws them, and into the app,
// whose activitykit reports a node without a view here in `degraded_features` as `layout.custom.<name>`. Link both
// targets to the `ActivityKitViews` product. Keep the Objective-C name: both sides find the views by it.
//
// A view gets its node's props: `props.number("level")`, `props.string("label")`, `props.bool("full")`; a prop bound to
// a value has the value of the latest update. A Live Activity has no network and little memory: draw with shapes, text
// and the extension's images.
@available(iOS 16.1, *)
@objc(ActivityKitCustomViews)
final class CustomViews: ActivityKitCustomViewRegistry {
    override class var views: [String: ActivityKitCustomView] {
        [
            // custom("ring").prop("level", Bound::key("level")) draws:
            "ring": ActivityKitCustomView { props in
                Circle().trim(from: 0, to: props.number("level") ?? 0).stroke(lineWidth: 4).rotationEffect(.degrees(-90))
            },
        ]
    }
}
