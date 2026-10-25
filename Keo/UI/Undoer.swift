import SwiftUI
import UIKit

/// One step back, for the personalisation that is easy to lose by accident.
///
/// Removing three favourites at once took them out of the list instantly and left nothing to
/// find them by — the list is the only place they existed. Nothing here touches the NAS, so
/// nothing here is dangerous; what it is, is *irretrievable*, which is worse in daily use.
///
/// A banner and a shake, deliberately both. The shake is the iOS mechanism, but nobody
/// discovers it — on its own the feature would exist without existing. The banner is what
/// makes it visible; the shake is what lets someone who knows it reach further back.
@MainActor
final class Undoer: ObservableObject {
    struct Step: Identifiable {
        let id = UUID()
        /// Already in the past tense, and counted: "3 favoris retirés".
        let label: String
        let revert: @Sendable () async -> Void
    }

    /// Shown for a few seconds. Separate from the stack because the banner is about the last
    /// thing you did, while the stack is about how far back you can go.
    @Published private(set) var banner: Step?
    @Published private(set) var undoing = false

    /// Bumped by every recorded action and by every undo.
    ///
    /// Each screen used to refresh its own badges right where the action happened, which
    /// worked until the action happened somewhere else: favouriting from the full-screen
    /// viewer left the grid behind it showing the old marks, and an undo refreshed nothing at
    /// all. Every mutation of the personalisation already passes through here to be made
    /// reversible, so this is the one place that knows something changed.
    @Published private(set) var revision = 0

    private var stack: [Step] = []
    private var hide: Task<Void, Never>?

    /// Deeper than the banner so a shake can walk back several steps, bounded so a long
    /// session cannot hold items alive for ever.
    private static let depth = 8
    private static let linger: Duration = .seconds(5)

    var canUndo: Bool { !stack.isEmpty }

    func record(_ label: String, revert: @escaping @Sendable () async -> Void) {
        let step = Step(label: label, revert: revert)
        stack.append(step)
        if stack.count > Self.depth { stack.removeFirst() }

        banner = step
        revision += 1
        hide?.cancel()
        hide = Task { [weak self] in
            try? await Task.sleep(for: Self.linger)
            guard !Task.isCancelled else { return }
            self?.banner = nil
        }
    }

    func undo() {
        guard !undoing, let step = stack.popLast() else { return }
        undoing = true
        hide?.cancel()
        banner = nil
        Task {
            await step.revert()
            undoing = false
            revision += 1
        }
    }

    /// "1 favori retiré" / "3 favoris retirés". Written once because every call site needs
    /// it and none of them should be the place a plural rule is got wrong — note that French
    /// keeps the singular at zero, which `> 1` gets right and `!= 1` would not.
    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n) \(n > 1 ? many : one)"
    }

    /// Nothing to go back to once the thing you would go back to is gone — a rebuilt index,
    /// a disconnection. Called rather than left to rot.
    func forget() {
        hide?.cancel()
        stack.removeAll()
        banner = nil
    }
}

// MARK: - The banner

/// Sits above the tab bar, and again inside the viewer — a `fullScreenCover` covers the root,
/// so an overlay on the root would never be seen from the photo.
struct UndoBanner: View {
    @EnvironmentObject private var undoer: Undoer

    var body: some View {
        if let step = undoer.banner {
            HStack(spacing: 12) {
                Image(systemName: "arrow.uturn.backward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(step.label)
                    .font(.footnote)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Annuler") { undoer.undo() }
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
            .frame(maxWidth: 420)
            .background(.bar, in: Capsule())
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(.snappy(duration: 0.25), value: step.id)
        }
    }
}

// MARK: - The shake

/// A zero-sized first responder, because SwiftUI has no shake gesture and the alternatives
/// are swizzling `UIWindow` or reaching for a deprecated window list.
///
/// It gives up first responder the moment a text field wants it, which is the behaviour we
/// want anyway: while you are typing, a shake belongs to the text field's own undo.
struct ShakeCatcher: UIViewControllerRepresentable {
    let onShake: () -> Void

    func makeUIViewController(context: Context) -> Catcher {
        let controller = Catcher()
        controller.onShake = onShake
        return controller
    }

    func updateUIViewController(_ controller: Catcher, context: Context) {
        controller.onShake = onShake
    }

    final class Catcher: UIViewController {
        var onShake: (() -> Void)?

        override var canBecomeFirstResponder: Bool { true }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            becomeFirstResponder()
        }

        override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
            guard motion == .motionShake else {
                super.motionEnded(motion, with: event)
                return
            }
            onShake?()
        }
    }
}
