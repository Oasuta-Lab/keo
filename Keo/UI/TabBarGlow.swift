import SwiftUI
import UIKit

/// While indexing runs, the tab bar's outline gets traced around.
///
/// The two-point line at the top of the screen said the same thing, but in the wrong place:
/// it occupied the edge that navigation bars already claim, and it had nothing to do with
/// what it announced. The tab bar, on the other hand, is the only element present on all
/// five screens, and it floats — its outline is free.
///
/// It stays **indeterminate**, and that is not a shortcut. The indexer knows the progress of
/// the current folder and nothing else: the total number of folders is only known once the
/// walk is over. An outline filling from zero to one would jump backwards at every folder.
/// The travelling segment says "something is working" without pretending to say "this far".
///
/// Placed **inside** the bar rather than over it, as a UIKit view constrained to its edges.
/// That is what makes it follow the scroll-away collapse, rotation and the accessibility
/// sizes for free — all moments where a layer drawn at coordinates measured once would end
/// up beside the thing it outlines.
struct TabBarGlow: UIViewRepresentable {
    let running: Bool

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView(frame: .zero)
        anchor.isUserInteractionEnabled = false
        anchor.isHidden = true
        return anchor
    }

    func updateUIView(_ anchor: UIView, context: Context) {
        // After the current run-loop turn: on the first call the view is not in a window yet,
        // so the tab bar cannot be found.
        DispatchQueue.main.async {
            guard let bar = Self.tabBar(from: anchor) else { return }
            if running { GlowLayerView.attach(to: bar) } else { GlowLayerView.detach(from: bar) }
        }
    }

    static func dismantleUIView(_ anchor: UIView, coordinator: ()) {
        if let bar = tabBar(from: anchor) { GlowLayerView.detach(from: bar) }
    }

    /// The window's tab bar. Walked up to through the responder chain rather than searched
    /// for in the view tree: SwiftUI rebuilds the tree on every tab change, not the
    /// controller hierarchy.
    private static func tabBar(from view: UIView) -> UITabBar? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let tabs = next as? UITabBarController { return tabs.tabBar }
            responder = next
        }
        // The view lives in a child hosting controller the chain does not always traverse:
        // walk back down from the root, where there is only one bar.
        return view.window?.rootViewController.flatMap(firstTabBarController)?.tabBar
    }

    private static func firstTabBarController(_ root: UIViewController) -> UITabBarController? {
        if let tabs = root as? UITabBarController { return tabs }
        for child in root.children {
            if let found = firstTabBarController(child) { return found }
        }
        return root.presentedViewController.flatMap(firstTabBarController)
    }
}

/// The glowing segment itself.
private final class GlowLayerView: UIView {
    private let trail = CAShapeLayer()
    private let shimmer = CAGradientLayer()

    private static let tag = 0x6B_65_6F_01      // "keo", plus enough to not be mistaken

    // MARK: Attach and detach

    static func attach(to bar: UITabBar) {
        guard let host = capsule(of: bar) else { return }
        if host.viewWithTag(tag) != nil { return }
        // Kept: the day iOS changes how its bar is composed, this line is what will say the
        // outline has settled somewhere else, instead of a crooked frame to explain.
        trace("glow host=\(host.frame) dans barre=\(bar.bounds)")

        let glow = GlowLayerView(frame: host.bounds)
        glow.tag = tag
        glow.isUserInteractionEnabled = false
        glow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(glow)
        glow.start()
    }

    static func detach(from bar: UITabBar) {
        guard let host = capsule(of: bar), let glow = host.viewWithTag(tag) else { return }
        UIView.animate(withDuration: 0.25) { glow.alpha = 0 } completion: { _ in
            glow.removeFromSuperview()
        }
    }

    /// What to outline: the glass pill, not the bar.
    ///
    /// Since iOS 26 the tab bar is a full-width container inside which two things float —
    /// the tab pill, and the detached search button. Measured on the device: the bar is
    /// 420 × 83, the pill 308 × 62 at x = 21, the button 62 × 62 at x = 337. Outlining the
    /// bar therefore drew a frame that started at the right edge and ran well past it, over
    /// the gap and the search button.
    ///
    /// The criterion is the **width**, and nothing else. The first version looked for a
    /// corner radius, assuming a capsule declares one: none of these views carries any, the
    /// glass is drawn some other way. The class name would settle it, but it is private and
    /// changes without notice; the width distinguishes the pill from its two neighbours by
    /// a factor of five and depends on no version.
    private static func capsule(of bar: UITabBar) -> UIView? {
        // Under half the bar's width, it is the detached button or the selected tab's blob —
        // not the pill. In that case, drawing nothing beats drawing in the wrong place.
        let widest = bar.subviews.max { $0.bounds.width < $1.bounds.width }
        guard let widest, widest.bounds.width > bar.bounds.width * 0.5 else { return nil }
        return widest
    }

    // MARK: Drawing

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        trail.fillColor = nil
        trail.strokeColor = UIColor.white.cgColor
        trail.lineWidth = 2.5
        trail.lineCap = .round

        // The gradient provides the shimmer; the path serves as its mask, so only the
        // stretch of outline being traced lights up. The other way round — a solid coloured
        // stroke — does not shimmer, it slides.
        shimmer.colors = [UIColor.clear.cgColor,
                          UIColor(named: "AccentColor")?.cgColor ?? UIColor.systemOrange.cgColor,
                          UIColor.white.withAlphaComponent(0.9).cgColor,
                          UIColor(named: "AccentColor")?.cgColor ?? UIColor.systemOrange.cgColor,
                          UIColor.clear.cgColor]
        shimmer.locations = [0, 0.25, 0.5, 0.75, 1]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.mask = trail
        shimmer.shadowColor = UIColor(named: "AccentColor")?.cgColor ?? UIColor.systemOrange.cgColor
        shimmer.shadowRadius = 6
        shimmer.shadowOpacity = 0.55
        shimmer.shadowOffset = .zero
        layer.addSublayer(shimmer)
    }

    required init?(coder: NSCoder) { fatalError("jamais chargé depuis un storyboard") }

    override func layoutSubviews() {
        super.layoutSubviews()
        shimmer.frame = bounds
        // The stroke is centred on the edge: half its thickness would spill over otherwise,
        // and the glass capsule clips whatever sticks out.
        let inset = trail.lineWidth / 2
        let rounded = bounds.insetBy(dx: inset, dy: inset)
        trail.frame = bounds
        trail.path = UIBezierPath(roundedRect: rounded,
                                  cornerRadius: rounded.height / 2).cgPath
    }

    // MARK: Motion

    /// Two animations on the same path, offset: the end sets off ahead, the start catches it
    /// up. A segment is born, stretches, travels the outline and closes — rather than a
    /// solid stroke going round, which ends up looking like a permanent border.
    private func start() {
        let turn: CFTimeInterval = 2.4

        let head = CABasicAnimation(keyPath: "strokeEnd")
        head.fromValue = 0
        head.toValue = 1
        head.duration = turn
        head.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let tail = CABasicAnimation(keyPath: "strokeStart")
        tail.fromValue = 0
        tail.toValue = 1
        tail.duration = turn
        tail.beginTime = turn * 0.35
        tail.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

        let group = CAAnimationGroup()
        group.animations = [head, tail]
        group.duration = turn * 1.35
        group.repeatCount = .infinity
        // Without this the path reappears whole between two laps, and the outline blinks.
        group.fillMode = .backwards
        trail.add(group, forKey: "parcours")

        // The gradient slides under the mask: that is what makes the segment shimmer rather
        // than leaving it a single tint.
        let slide = CABasicAnimation(keyPath: "locations")
        slide.fromValue = [-0.6, -0.35, -0.1, 0.15, 0.4]
        slide.toValue = [0.6, 0.85, 1.1, 1.35, 1.6]
        slide.duration = 1.6
        slide.repeatCount = .infinity
        shimmer.add(slide, forKey: "scintillement")

        alpha = 0
        UIView.animate(withDuration: 0.3) { self.alpha = 1 }
    }

    /// iOS drops the animations of a layer that leaves the screen — on return, the outline
    /// would be frozen on its last frame.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, trail.animation(forKey: "parcours") == nil { start() }
    }
}
