import Foundation

/// The one line the home screen gets to say about indexing.
///
/// It used to say « 4 781 dossiers sur 4 802 », which is the wrong answer twice over: the
/// subtraction is left to the reader, and the branch barely ever shows — the periodic
/// discovery stamps every folder it lists, so folders are caught up long before files are. A
/// ratio of folders is machinery talking about itself.
///
/// What replaces it is an order of precedence, not a formula: in any given moment exactly one
/// thing is worth a line, and the rarest of them is the most valuable. A failure outranks work
/// in progress, work in progress outranks a backlog, and a backlog outranks reassurance.
/// Reassurance, when it is all that is left, is freshness — « Vérifié hier » answers "can I
/// trust what I am looking at" where a grand total answers nothing.
///
/// Pure and outside SwiftUI so the order can be pinned down, like `RailLayout` and
/// `WalkOutcome`. `Tests/indexation.swift` walks it state by state.
enum IndexingLine {
    /// Everything the line is allowed to know. Gathered by the caller from the indexer and the
    /// home summary, so the order below can be read without either.
    struct Facts {
        var running = false
        var paused = false
        /// Published every twenty reads during a walk. A figure that moves between two glances
        /// is the only proof the pass is alive rather than merely flagged — the distinction
        /// `isStalled` exists to make.
        var datesRead = 0
        /// Nothing indexed at all: the index has never been built.
        var empty = false
        /// Folders the box would not list, at the last complete pass.
        var unreachable = 0
        /// Files known to exist whose capture date has not been read yet.
        var unread = 0
        var lastRun: Date?
    }

    /// The line, and whether it should be worn in `Theme.warning`.
    ///
    /// Amber is for the two states the owner can act on — something failed, or a pass is
    /// waiting to be resumed. A backlog is not amber: discovery creates one on its own every
    /// time photos arrive, and colouring the normal course of events teaches people to ignore
    /// the colour.
    static func detail(_ facts: Facts, now: Date = Date()) -> (text: String, warning: Bool) {
        if facts.running {
            // Not « En cours… »: an ellipsis proves a flag is raised, a count proves work.
            return (facts.datesRead > 0
                    ? "En cours · " + Plural.count(facts.datesRead, "date lue", "dates lues")
                    : "En cours…", false)
        }
        if facts.paused {
            let rest = facts.unread > 0
                     ? " · reste \(facts.unread.formatted())"
                     : ""
            return ("Interrompue" + rest, true)
        }
        if facts.empty { return ("Pas encore commencée", false) }
        // Said before the backlog, and in amber: a share that was unmounted leaves an index
        // quietly rotting, and nothing else on the home screen would ever mention it.
        if facts.unreachable > 0 {
            return (Plural.count(facts.unreachable, "dossier inaccessible",
                                 "dossiers inaccessibles"), true)
        }
        if facts.unread > 0 {
            return (Plural.count(facts.unread, "fichier à lire", "fichiers à lire"), false)
        }
        guard let lastRun = facts.lastRun else { return ("À jour", false) }
        // The machine register, not `HumanDate`: this is the day Keo last looked, not a day
        // someone lived. « Un mardi de juillet » for a sweep over a NAS would be absurd, and
        // the system's own relative style is already right in every locale.
        return ("Vérifié " + lastRun.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)),
                false)
    }
}
