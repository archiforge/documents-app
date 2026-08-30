import Foundation

/// Retention rules for the trash.
///
/// Trashed documents stay recoverable for a fixed window; once the window
/// elapses the store purges them (on launch). The boundary is exact: a
/// document trashed precisely `retentionDays` ago survives one more purge
/// pass and reports "deletes today".
enum TrashPolicy {
    /// How many days a document stays in the trash before automatic purge.
    static let retentionDays = 30

    /// The retention window as a time interval.
    static var retentionInterval: TimeInterval {
        TimeInterval(retentionDays) * 86_400
    }

    /// The moment a document trashed at `trashedAt` leaves the trash.
    static func purgeDate(trashedAt: Date) -> Date {
        trashedAt.addingTimeInterval(retentionInterval)
    }

    /// Whole days left until purge, rounded up and never negative. Zero means
    /// the document purges on the next pass ("deletes today").
    static func remainingDays(trashedAt: Date, now: Date) -> Int {
        let remaining = purgeDate(trashedAt: trashedAt).timeIntervalSince(now)
        guard remaining > 0 else { return 0 }
        return Int((remaining / 86_400).rounded(.up))
    }
}
