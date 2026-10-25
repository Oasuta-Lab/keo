import SwiftUI

/// The navigation path of the stack a view sits in, when it has one.
///
/// Browsing is recursive: `BrowserView` pushes itself, so it cannot own the destination that
/// presents the next level — a stack holding several destinations for one value rebuilds
/// them, which is what made the breadcrumb loop. The stack declares its destinations once,
/// at the root, and hands its path down here so any level can push or pop without owning it.
extension EnvironmentValues {
    @Entry var stackPath: Binding<NavigationPath>?
}
