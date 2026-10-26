import BackgroundTasks
import SwiftUI

/// Goes to check, every now and then, whether the NAS has received anything.
///
/// Without it, Keo only discovered a file when someone opened the folder holding it or
/// started an indexing pass by hand. Until one of the two happened, nothing said there was
/// anything new: no counter, no amber on the « Indexation » row, no badge on the folder. The
/// only way to find out was to think of it.
///
/// It only **lists**. It reads no dates, because reading costs one network round trip per
/// file and that gesture remains the owner's. What it keeps alive is the knowledge of what
/// exists — after which the home screen says « N fichiers à lire » on its own and the row
/// turns amber.
///
/// Three reasons a pass costs little on a library that has not moved: a folder whose
/// modification date and child count are unchanged is skipped without being listed; the
/// technical subtrees are never walked; and nothing is downloaded. On a library that has
/// moved, only the branches that moved are listed.
///
/// `BGAppRefresh` and not `BGProcessing`: this is the short, frequent task, the one iOS
/// grants willingly and schedules by what it knows of usage, battery and network. We ask for
/// an hour at the earliest; the system decides the rest, and owes us nothing.
@MainActor
enum PeriodicDiscovery {
    static let identifier = "com.oasutalab.keo.discovery"

    /// An hour from now at the earliest. Not a promise: iOS moves it up or back from what it
    /// knows about the device, and that is just as well — nobody is waiting for this pass.
    private static let earliest: TimeInterval = 3_600

    private nonisolated(unsafe) static var registered = false

    /// Called at launch and at the end of every pass, so that there is always exactly one
    /// request pending. `submit` replaces a request with the same identifier, so calling it
    /// twice does not create two passes.
    static func schedule() {
        register()
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliest)
        do {
            try BGTaskScheduler.shared.submit(request)
            trace("discovery scheduled")
        } catch {
            // No visible consequence: manual discovery still works, and the app has nothing
            // to say about a service the system is entitled to refuse.
            trace("discovery schedule failed: \(error.localizedDescription)")
        }
    }

    /// Called from `KeoApp.init`, never from a view: `BGTaskScheduler` requires every handler
    /// to be registered before launch ends, and it terminates the app when it wakes it for an
    /// identifier nobody claimed. A `.task` runs after the first render, which a background
    /// launch may never reach.
    static func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier,
                                        using: .main) { task in
            MainActor.assumeIsolated { run(task as? BGAppRefreshTask) }
        }
    }

    private static func run(_ task: BGAppRefreshTask?) {
        guard let task else { return }
        // The next one is requested right away: if it waited for the end, a pass cut short
        // by expiration would take the whole chain down with it.
        schedule()

        guard let store = Store.shared, let client = store.client else {
            trace("discovery skipped: pas de client")
            task.setTaskCompleted(success: false)
            return
        }
        // Nothing to attempt while the box refuses the application: the walk would fail at
        // the first folder, and there is nobody at the screen to answer. The state is told at
        // the next opening, by the banner.
        guard !store.authorizationLost else {
            trace("discovery skipped: autorisation perdue")
            task.setTaskCompleted(success: false)
            return
        }

        let indexer = Indexer.shared
        // A pass already underway does better than this one would, and two walks in parallel
        // over the same index do not add up, they get in each other's way.
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
            // Nobody asked for anything: a wake-up that finds nothing must not greet the
            // owner, two hours later, with a card saying « rien de neuf ». A wake-up that
            // finds something, yes — that is the whole point of the pass.
            if indexer.lastSummary?.changedNothing == true { indexer.lastSummary = nil }
            trace("discovery end")
            task.setTaskCompleted(success: true)
        }
    }
}
