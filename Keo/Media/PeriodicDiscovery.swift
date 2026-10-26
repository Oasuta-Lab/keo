import BackgroundTasks
import SwiftUI

/// Va voir, de temps en temps, si le NAS a reçu quelque chose.
///
/// Sans elle, Keo ne découvrait un fichier que si on ouvrait le dossier qui le contient ou si
/// on lançait une indexation à la main. Tant qu'on n'avait pas fait l'un des deux, rien ne
/// signalait qu'il y avait du neuf : ni compteur, ni ambre sur la rangée « Indexation », ni
/// puce dans le dossier. On ne pouvait l'apprendre qu'en y pensant.
///
/// Elle **liste** seulement. Elle ne lit aucune date, parce que lire coûte un aller-retour
/// réseau par fichier et que ce geste-là reste celui du propriétaire. Ce qu'elle fait tenir,
/// c'est la connaissance de ce qui existe — après quoi l'accueil dit « N fichiers à lire » de
/// lui-même et la rangée passe à l'ambre.
///
/// Trois raisons pour lesquelles un passage coûte peu sur une bibliothèque qui n'a pas bougé :
/// un dossier dont la date de modification et le nombre d'enfants sont inchangés est sauté
/// sans être listé ; les sous-arbres techniques ne sont jamais parcourus ; et rien n'est
/// téléchargé. Sur une bibliothèque qui a bougé, seules les branches qui ont bougé sont
/// listées.
///
/// `BGAppRefresh` et non `BGProcessing` : c'est la tâche courte et fréquente, celle qu'iOS
/// accorde volontiers et dont il choisit le moment selon l'usage, la batterie et le réseau.
/// On demande une heure au plus tôt ; le système décide du reste, et ne nous doit rien.
@MainActor
enum PeriodicDiscovery {
    static let identifier = "com.oasutalab.keo.discovery"

    /// Au plus tôt dans une heure. Ce n'est pas une promesse : iOS avance ou retarde selon ce
    /// qu'il sait de l'appareil, et c'est très bien ainsi — personne n'attend ce passage.
    private static let earliest: TimeInterval = 3_600

    private nonisolated(unsafe) static var registered = false

    /// Appelée au lancement et à chaque fin de passage, pour qu'il y ait toujours exactement
    /// une demande en attente. `submit` remplace une demande de même identifiant, donc en
    /// appeler deux fois ne crée pas deux passages.
    static func schedule() {
        register()
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        do {
            try BGTaskScheduler.shared.submit(request)
            trace("discovery scheduled")
        } catch {
            // Sans conséquence visible : la découverte manuelle marche toujours, et l'app
            // n'a rien à dire sur un service que le système a le droit de refuser.
            trace("discovery schedule failed: \(error.localizedDescription)")
        }
    }

    private static func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier,
                                        using: .main) { task in
            MainActor.assumeIsolated { run(task as? BGAppRefreshTask) }
        }
    }

    private static func run(_ task: BGAppRefreshTask?) {
        guard let task else { return }
        // La suivante est demandée tout de suite : si l'on attendait la fin, un passage
        // interrompu par l'expiration emporterait la chaîne avec lui.
        schedule()

        guard let store = Store.shared, let client = store.client else {
            trace("discovery skipped: pas de client")
            task.setTaskCompleted(success: false)
            return
        }
        // Rien à tenter tant que la box refuse l'application : la marche échouerait au premier
        // dossier, et il n'y a personne devant l'écran pour y répondre. L'état est dit à la
        // prochaine ouverture, par la bannière.
        guard !store.authorizationLost else {
            trace("discovery skipped: autorisation perdue")
            task.setTaskCompleted(success: false)
            return
        }

        let indexer = Indexer.shared
        // Un passage déjà en cours fait mieux que celui-ci, et deux marches en parallèle sur
        // le même index ne s'additionnent pas, elles se gênent.
        guard !indexer.state.isRunning else {
            trace("discovery skipped: indexation déjà en cours")
            task.setTaskCompleted(success: true)
            return
        }

        task.expirationHandler = {
            MainActor.assumeIsolated {
                trace("discovery expired")
                Indexer.shared.pauseKeepingResume()
            }
        }

        trace("discovery start")
        indexer.start(client: client, scope: .discover)

        Task { @MainActor in
            while indexer.state.isRunning {
                try? await Task.sleep(for: .seconds(2))
            }
            trace("discovery end")
            task.setTaskCompleted(success: true)
        }
    }
}
