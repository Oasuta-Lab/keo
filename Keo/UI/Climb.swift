import Foundation

/// What tapping a crumb does to the navigation stack.
///
/// Pure and outside SwiftUI so the pop/push arithmetic can be checked — this is the exact
/// arithmetic the looping-breadcrumb bug lived in. Browsing down from the root leaves the
/// trail's ancestors in the stack, so reaching a crumb pops the levels between. Arriving
/// sideways — from a search result — never visited them, so there is nothing to pop and the
/// crumb is pushed instead.
extension Breadcrumb {
    enum Move: Equatable {
        case pop(levels: Int)
        case push
    }

    /// `step` is the crumb's index in a trail of `depth` crumbs; `stacked` is how many views
    /// the navigation stack holds above its root.
    static func move(toStep step: Int, of depth: Int, stacked: Int) -> Move {
        let levels = depth - 1 - step
        return stacked >= levels ? .pop(levels: levels) : .push
    }
}
