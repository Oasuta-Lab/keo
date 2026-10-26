import Foundation

/// « 1 élément », « 2 éléments », « 0 élément ».
///
/// Zéro est singulier en français, contrairement à l'anglais — c'est la seule subtilité, et
/// c'est précisément celle que les deux règles de l'app avaient fini par écrire différemment :
/// `n > 1` côté app, `n == 1 ? "" : "s"` côté widget, qui affichait « 0 photos ».
///
/// Le nombre passe par `formatted()` plutôt que par une interpolation nue, pour que les
/// milliers prennent l'espace insécable attendu : « 8 380 éléments ».
enum Plural {
    static func count(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n > 1 ? many : one)"
    }
}
