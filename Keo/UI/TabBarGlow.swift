import SwiftUI
import UIKit

/// Pendant l'indexation, le contour de la barre d'onglets se parcourt.
///
/// Le trait de deux points en haut de l'écran disait la même chose, mais au mauvais endroit :
/// il occupait le bord que les barres de navigation revendiquent déjà, et il n'avait rien à
/// voir avec ce qu'il annonçait. La barre d'onglets, elle, est le seul élément présent sur
/// les cinq écrans, et elle flotte — son contour est libre.
///
/// Elle reste **indéterminée**, et ce n'est pas une facilité. L'indexeur connaît l'avancement
/// du dossier courant et rien d'autre : le nombre total de dossiers n'est connu qu'une fois la
/// marche finie. Un contour qui se remplirait de zéro à un repartirait en arrière à chaque
/// dossier. Le segment qui tourne dit « ça travaille » sans prétendre dire « à tel point ».
///
/// Posé **dans** la barre plutôt que par-dessus, en vue UIKit contrainte à ses bords. C'est ce
/// qui le fait suivre gratuitement la rétractation au défilement, la rotation et le passage en
/// accessibilité — autant de moments où un calque dessiné à des coordonnées relevées une fois
/// se retrouverait à côté de ce qu'il entoure.
struct TabBarGlow: UIViewRepresentable {
    let running: Bool

    func makeUIView(context: Context) -> UIView {
        let anchor = UIView(frame: .zero)
        anchor.isUserInteractionEnabled = false
        anchor.isHidden = true
        return anchor
    }

    func updateUIView(_ anchor: UIView, context: Context) {
        // Après le tour de boucle courant : au premier appel la vue n'est pas encore dans une
        // fenêtre, donc la barre d'onglets est introuvable.
        DispatchQueue.main.async {
            guard let bar = Self.tabBar(from: anchor) else { return }
            if running { GlowLayerView.attach(to: bar) } else { GlowLayerView.detach(from: bar) }
        }
    }

    static func dismantleUIView(_ anchor: UIView, coordinator: ()) {
        if let bar = tabBar(from: anchor) { GlowLayerView.detach(from: bar) }
    }

    /// La barre d'onglets de la fenêtre. Remontée par la chaîne des répondeurs plutôt que
    /// cherchée dans l'arbre des vues : SwiftUI reconstruit l'arbre à chaque changement
    /// d'onglet, pas la hiérarchie des contrôleurs.
    private static func tabBar(from view: UIView) -> UITabBar? {
        var responder: UIResponder? = view
        while let next = responder?.next {
            if let tabs = next as? UITabBarController { return tabs.tabBar }
            responder = next
        }
        // La vue vit dans un contrôleur hôte enfant que la chaîne ne traverse pas toujours :
        // on redescend depuis la racine, où il n'y a qu'une seule barre.
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

/// Le segment lumineux lui-même.
private final class GlowLayerView: UIView {
    private let trail = CAShapeLayer()
    private let shimmer = CAGradientLayer()

    private static let tag = 0x6B_65_6F_01      // "keo", et de quoi ne pas se confondre

    // MARK: Pose et dépose

    static func attach(to bar: UITabBar) {
        guard let host = capsule(of: bar) else { return }
        if host.viewWithTag(tag) != nil { return }
        // Gardée : le jour où iOS change la composition de sa barre, c'est cette ligne qui
        // dira que le contour s'est reposé ailleurs, au lieu d'un cadre de travers à expliquer.
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

    /// Ce qu'il faut entourer : la pilule de verre, pas la barre.
    ///
    /// Depuis iOS 26 la barre d'onglets est un conteneur pleine largeur dans lequel flottent
    /// deux choses — la pilule des onglets, et le bouton de recherche détaché. Mesuré sur
    /// l'appareil : la barre fait 420 × 83, la pilule 308 × 62 à x = 21, le bouton 62 × 62 à
    /// x = 337. Entourer la barre traçait donc un cadre qui partait du bon bord et filait
    /// bien au-delà, par-dessus le vide et le bouton de recherche.
    ///
    /// Le critère est la **largeur**, et rien d'autre. La première version cherchait un rayon
    /// d'angle, en supposant qu'une capsule en déclare un : aucune de ces vues n'en porte, le
    /// verre est dessiné autrement. Le nom de classe trancherait, mais il est privé et change
    /// sans prévenir ; la largeur, elle, distingue la pilule de ses deux voisines par un
    /// facteur cinq et ne dépend d'aucune version.
    private static func capsule(of bar: UITabBar) -> UIView? {
        // Sous la moitié de la barre, c'est le bouton détaché ou la pastille de l'onglet
        // choisi — pas la pilule. Dans ce cas on préfère ne rien dessiner à dessiner à côté.
        let widest = bar.subviews.max { $0.bounds.width < $1.bounds.width }
        guard let widest, widest.bounds.width > bar.bounds.width * 0.5 else { return nil }
        return widest
    }

    // MARK: Dessin

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        trail.fillColor = nil
        trail.strokeColor = UIColor.white.cgColor
        trail.lineWidth = 2.5
        trail.lineCap = .round

        // Le dégradé donne le scintillement ; le tracé lui sert de masque, donc seule la
        // portion de contour parcourue s'allume. L'inverse — un trait coloré uni — ne
        // scintille pas, il glisse.
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
        // Le trait est centré sur le bord : la moitié de son épaisseur déborderait sinon, et
        // la capsule de verre coupe ce qui dépasse.
        let inset = trail.lineWidth / 2
        let rounded = bounds.insetBy(dx: inset, dy: inset)
        trail.frame = bounds
        trail.path = UIBezierPath(roundedRect: rounded,
                                  cornerRadius: rounded.height / 2).cgPath
    }

    // MARK: Mouvement

    /// Deux animations sur le même tracé, décalées : la fin part devant, le début la rattrape.
    /// Un segment naît, s'étire, parcourt le contour et se referme — plutôt qu'un trait plein
    /// qui tournerait, lequel finit par ressembler à une bordure permanente.
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
        // Sans cela le tracé réapparaît entier entre deux tours, et le contour clignote.
        group.fillMode = .backwards
        trail.add(group, forKey: "parcours")

        // Le dégradé glisse sous le masque : c'est lui qui fait scintiller le segment plutôt
        // que de le laisser d'une seule teinte.
        let slide = CABasicAnimation(keyPath: "locations")
        slide.fromValue = [-0.6, -0.35, -0.1, 0.15, 0.4]
        slide.toValue = [0.6, 0.85, 1.1, 1.35, 1.6]
        slide.duration = 1.6
        slide.repeatCount = .infinity
        shimmer.add(slide, forKey: "scintillement")

        alpha = 0
        UIView.animate(withDuration: 0.3) { self.alpha = 1 }
    }

    /// iOS vide les animations d'un calque sorti de l'écran — au retour, le contour serait
    /// figé sur sa dernière image.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil, trail.animation(forKey: "parcours") == nil { start() }
    }
}
