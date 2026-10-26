import Foundation

/// What a finished indexing pass changed, in the words it will be shown in.
///
/// It lives outside SwiftUI for the usual reason — the interesting part is not the card, it is
/// deciding what deserves to be said. A pass produces nine counters and almost all of them are
/// zero almost every time; printing them all turns the one line that matters ("three new
/// files") into something to search for. So the rule here is that **a zero is never spoken**,
/// and the lines come in the order someone actually cares about them.
///
/// `vanished` is deliberately not called "deleted". Keo never deletes anything on the NAS — a
/// file counted here is one the box stopped listing, whatever did it. Saying "supprimés" in a
/// read-only app would read as a confession.
struct WalkSummary: Equatable, Sendable, Codable {
    /// Files seen for the first time in a folder Keo already knew.
    var arrived = 0
    /// Rows the sweep removed because the box no longer lists them.
    var vanished = 0
    var foldersVisited = 0
    /// Folders whose stamp was unchanged, so they were never listed. The cheap half of a pass.
    var foldersSkipped = 0
    var datesRead = 0
    var dateless = 0
    /// Files whose date came from an identical twin elsewhere in the index rather than from
    /// the box — a folder renamed or moved, keeping its photos. Said because it is the one
    /// counter that explains a pass finishing far faster than the file count suggests.
    var adopted = 0
    var unreadable = 0
    var indexedOverall = 0

    var changedNothing: Bool { arrived == 0 && vanished == 0 }

    /// The one line that would survive being the only line.
    var headline: String {
        switch (arrived, vanished) {
        case (0, 0):
            return "Rien de neuf"
        case (let new, 0):
            return Plural.count(new, "nouveau fichier", "nouveaux fichiers")
        case (0, let gone):
            return Plural.count(gone, "fichier disparu", "fichiers disparus")
        case (let new, let gone):
            return Plural.count(new, "nouveau fichier", "nouveaux fichiers")
                 + ", " + Plural.count(gone, "disparu", "disparus")
        }
    }

    /// The rest, shortest-lived first, each line dropped when it has nothing to say.
    var details: [String] {
        var lines: [String] = []

        // Unchanged folders are the reason a pass over a quiet library costs nothing. Said out
        // loud, because a pass reporting "4 dossiers parcourus" on a NAS of eight thousand
        // otherwise looks like it gave up halfway.
        //
        // The three cases are spelled out rather than concatenated, because the common one on
        // a settled library is *zero* visited and everything skipped — and "0 dossier
        // parcouru, 8 300 inchangés" is the zero this type exists to not say.
        switch (foldersVisited, foldersSkipped) {
        case (0, 0):
            break
        case (0, let skipped):
            lines.append(Plural.count(skipped, "dossier inchangé", "dossiers inchangés"))
        case (let visited, 0):
            lines.append(Plural.count(visited, "dossier parcouru", "dossiers parcourus"))
        case (let visited, let skipped):
            lines.append(Plural.count(visited, "dossier parcouru", "dossiers parcourus")
                       + ", \(skipped.formatted()) inchangés")
        }

        if datesRead > 0 {
            var read = Plural.count(datesRead, "date de prise de vue lue",
                                    "dates de prise de vue lues")
            if dateless > 0 { read += ", \(dateless.formatted()) sans date" }
            lines.append(read)
        }

        if adopted > 0 {
            lines.append(Plural.count(adopted, "date retrouvée après un déplacement",
                                      "dates retrouvées après un déplacement"))
        }

        if unreadable > 0 {
            lines.append(Plural.count(unreadable, "fichier illisible", "fichiers illisibles"))
        }

        if indexedOverall > 0 {
            lines.append(Plural.count(indexedOverall, "fichier indexé en tout",
                                      "fichiers indexés en tout"))
        }

        return lines
    }
}
