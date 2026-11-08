import Foundation
import SwiftUI

// The registry of `custom` layout nodes, from the plugin's LiveActivityCustomRegistry.swift. The widget draws the views;
// the app reads which names have one, to report the others in `degraded_features` as `layout.custom.<name>`. Both
// targets compile the app's subclass, so both link this product. It depends on nothing else of the package, so the app
// links it without a second copy of the Swift code in the Rust library.

/// The props of a `custom` node as its view gets them: literals as the layout wrote them, and bound props with the value
/// of the current update. A prop that the node does not set is absent.
@available(iOS 16.1, *)
public struct ActivityKitCustomProps {
    public enum Value: Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
    }

    public let values: [String: Value]

    public init(values: [String: Value]) { self.values = values }

    public subscript(key: String) -> Value? { values[key] }

    public func string(_ key: String) -> String? {
        if case .string(let text)? = values[key] { return text } else { return nil }
    }

    public func number(_ key: String) -> Double? {
        if case .number(let number)? = values[key] { return number } else { return nil }
    }

    public func bool(_ key: String) -> Bool? {
        if case .bool(let flag)? = values[key] { return flag } else { return nil }
    }
}

/// One registered view: what it draws for the props of its node.
@available(iOS 16.1, *)
public struct ActivityKitCustomView {
    public let make: (ActivityKitCustomProps) -> AnyView

    public init<Content: View>(@ViewBuilder _ make: @escaping (ActivityKitCustomProps) -> Content) {
        self.make = { AnyView(make($0)) }
    }
}

/// Subclass it once, under the Objective-C name `ActivityKitCustomViews`, in a file that both the app and the widget
/// extension compile:
///
/// ```swift
/// @objc(ActivityKitCustomViews)
/// final class CustomViews: ActivityKitCustomViewRegistry {
///     override class var views: [String: ActivityKitCustomView] {
///         ["ring": ActivityKitCustomView { props in Circle().trim(from: 0, to: props.number("level") ?? 0).stroke(lineWidth: 4) }]
///     }
/// }
/// ```
@available(iOS 16.1, *)
open class ActivityKitCustomViewRegistry: NSObject {
    public static let className = "ActivityKitCustomViews"

    /// The views by the `name` of their nodes.
    open class var views: [String: ActivityKitCustomView] { [:] }

    /// The registered names, for the bridge in the app process.
    @objc public class var viewNames: [String] { views.keys.sorted() }

    /// The subclass named `ActivityKitCustomViews`, when the target compiles one.
    public static var registered: ActivityKitCustomViewRegistry.Type? {
        NSClassFromString(className) as? ActivityKitCustomViewRegistry.Type
    }
}
