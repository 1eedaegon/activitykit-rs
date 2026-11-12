import SwiftUI
import ActivityKitShared

/// How a node is presented beyond what it draws: the transition it comes and goes with, and whether the system hides
/// it on a locked device. Each is applied only when the node has it: a node that says nothing keeps the system's
/// transition, and stays as private as what holds it.
@available(iOS 16.1, *)
struct LayoutPresentationModifier: ViewModifier {
    let transition: LayoutTransition?
    let isSensitive: Bool

    @ViewBuilder func body(content: Content) -> some View {
        switch (transition, isSensitive) {
        case let (transition?, true): content.privacySensitive().transition(transition.transition)
        case let (transition?, false): content.transition(transition.transition)
        case (nil, true): content.privacySensitive()
        case (nil, false): content
        }
    }
}

@available(iOS 16.1, *)
extension LayoutTransition {
    /// The transitions the system runs in a Live Activity.
    var transition: AnyTransition {
        switch self {
        case .opacity: return .opacity
        case .slide: return .slide
        case .moveTop: return .move(edge: .top)
        case .moveBottom: return .move(edge: .bottom)
        case .moveLeading: return .move(edge: .leading)
        case .moveTrailing: return .move(edge: .trailing)
        case .pushTop: return .push(from: .top)
        case .pushBottom: return .push(from: .bottom)
        case .pushLeading: return .push(from: .leading)
        case .pushTrailing: return .push(from: .trailing)
        }
    }
}

@available(iOS 16.1, *)
extension LayoutContentTransition {
    var transition: ContentTransition {
        switch self {
        case .numericText: return .numericText()
        case .numericTextDown: return .numericText(countsDown: true)
        case .opacity: return .opacity
        case .interpolate: return .interpolate
        case .identity: return .identity
        }
    }
}
