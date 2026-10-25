import BackgroundTasks
import SwiftUI

/// Keeps a pass the owner started going once the phone is in a pocket.
///
/// A full pass is about fifteen minutes on this library — 41 000 files at the measured 50 to
/// 60 a second. The problem was never lasting for hours; it was not being cut off during that
/// quarter of an hour. iOS 26's `BGContinuedProcessingTask` is the exact shape of that: a task
/// *the user started by hand* survives backgrounding and locking, with a system progress gauge
/// and a cancel button, and the network stays available.
///
/// Two deliberate limits. The task is submitted on the tap, never speculatively — the system
/// only grants this to work someone asked for. And the indexer's background halt is skipped
/// only once the task has genuinely **begun**: a request iOS refused must still pause the
/// walk, or a suspended app is left running into exactly the failure this repository already
/// paid for once.
@MainActor
enum ContinuedIndexing {
    static let identifier = "com.oasutalab.keo.indexing"

    private nonisolated(unsafe) static var registered = false

    /// Progress must keep moving: the system expires a continued task whose progress stalls.
    /// Folders, not files — the file total is unknown until each folder is listed, and a total
    /// that jumps around reads worse than one that simply grows.
    static func submit(folders: Int) {
        guard #available(iOS 26.0, *) else {
            trace("bgcontinued indisponible (iOS < 26)")
            return
        }
        register()

        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: "Indexation de la bibliothèque",
            subtitle: "Keo lit les dates de tes photos"
        )
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            trace("bgcontinued submitted folders=\(folders)")
        } catch {
            // Not worth a word on screen: the pass runs anyway, it just stops at the lock
            // screen like it always did.
            trace("bgcontinued submit failed: \(error.localizedDescription)")
        }
    }

    @available(iOS 26.0, *)
    private static func register() {
        guard !registered else { return }
        registered = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier,
                                        using: .main) { task in
            MainActor.assumeIsolated {
                run(task as? BGContinuedProcessingTask)
            }
        }
    }

    @available(iOS 26.0, *)
    private static func run(_ task: BGContinuedProcessingTask?) {
        guard let task else { return }
        let indexer = Indexer.shared
        indexer.continuedTaskBegan()

        task.expirationHandler = {
            MainActor.assumeIsolated {
                Indexer.shared.continuedTaskEnded(expired: true)
            }
        }

        // Watches the walk and feeds the system gauge. Ends the task as soon as the walk
        // stops, whether it finished or was halted — a task that outlives its work is a task
        // the system expires for stalling.
        Task { @MainActor in
            let progress = task.progress
            progress.totalUnitCount = 1
            while indexer.state.isRunning {
                if let seen = indexer.state.progress {
                    let done = Int64(seen.foldersVisited + seen.foldersSkipped
                                   + seen.foldersExcluded)
                    // A total that only ever grows: the walk discovers folders as it goes,
                    // so the denominator is "what we know of so far", never a guess.
                    progress.totalUnitCount = max(progress.totalUnitCount, done + 1)
                    progress.completedUnitCount = done
                    trace("bgcontinued progress \(done)/\(progress.totalUnitCount)")
                }
                try? await Task.sleep(for: .seconds(5))
            }
            let finished = !indexer.resumeWanted
            indexer.continuedTaskEnded(expired: false)
            task.setTaskCompleted(success: finished)
        }
    }
}
