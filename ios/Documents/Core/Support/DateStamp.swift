import Foundation

/// Stable, sortable date stamp used in generated file names
/// ("Merged_2026-08-30.pdf", "Archive_2026-08-30.zip", ...).
@MainActor
enum DateStamp {
    static func day(for date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // Fixed zone keeps generated names stable and testable regardless of
        // where the device is.
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
