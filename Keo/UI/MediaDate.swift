import Foundation

/// What a viewer should print under a photo, and where the date came from.
///
/// The listing only gives the file's modification time, which on a NAS is frequently the day
/// the file was copied rather than the day it was taken. When the real capture date can be
/// read from the file, it wins and is shown bare; otherwise the modification date is shown
/// and labelled, so a misleading date is never passed off as the shooting date.
struct MediaDate: Equatable, Sendable {
    enum Source: Equatable, Sendable { case capture, modification }

    let date: Date
    let source: Source

    init?(capture: Date?, modification: Date?) {
        if let capture {
            self.date = capture
            self.source = .capture
        } else if let modification {
            self.date = modification
            self.source = .modification
        } else {
            return nil
        }
    }

    var text: String {
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        return source == .capture ? formatted : "Modifié le \(formatted)"
    }
}
