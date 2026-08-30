import Foundation

/// Groups documents by day for the Recent list, mirroring the Android
/// headers: "Today", "Yesterday", "N days ago", then "26 Jun" style dates.
/// Pure logic so grouping is unit-testable without SwiftData.
enum DateGrouping {
    struct Group: Equatable, Identifiable, Sendable {
        let key: String
        let title: String
        var id: String { key }
    }

    /// Section key + display title for one date relative to `now`.
    static func group(for date: Date, now: Date = .now, calendar: Calendar = .current) -> Group {
        let startOfNow = calendar.startOfDay(for: now)
        let startOfDay = calendar.startOfDay(for: date)
        let dayCount = calendar.dateComponents([.day], from: startOfDay, to: startOfNow).day ?? 0

        let title: String
        switch dayCount {
        case 0:
            title = "Today"
        case 1:
            title = "Yesterday"
        case 2...7:
            title = "\(dayCount) days ago"
        default:
            title = date.formatted(.dateTime.day().month(.abbreviated))
        }
        return Group(key: "\(startOfDay.timeIntervalSince1970)-\(title)", title: title)
    }

    /// Groups records (already filtered and sorted newest-first) preserving
    /// the incoming order; records on the same day share a section.
    static func groups(
        for dates: [Date],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Group] {
        var seen: Set<String> = []
        var ordered: [Group] = []
        for date in dates {
            let group = group(for: date, now: now, calendar: calendar)
            if seen.insert(group.key).inserted {
                ordered.append(group)
            }
        }
        return ordered
    }
}
