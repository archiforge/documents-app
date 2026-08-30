import XCTest
@testable import Documents

/// Day-grouping headers for the Recent list ("Today · 4 files" style).
final class DateGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    private var now: Date { date(2026, 8, 30) }

    func testSameDayIsTodayRegardlessOfHour() {
        let group = DateGrouping.group(for: date(2026, 8, 30, hour: 1), now: now, calendar: calendar)
        XCTAssertEqual(group.title, "Today")
    }

    func testPreviousDayIsYesterday() {
        let group = DateGrouping.group(for: date(2026, 8, 29), now: now, calendar: calendar)
        XCTAssertEqual(group.title, "Yesterday")
    }

    func testTwoToSevenDaysUseDayCount() {
        XCTAssertEqual(DateGrouping.group(for: date(2026, 8, 28), now: now, calendar: calendar).title, "2 days ago")
        XCTAssertEqual(DateGrouping.group(for: date(2026, 8, 23), now: now, calendar: calendar).title, "7 days ago")
    }

    func testOlderDatesUseDayMonthFormat() {
        let group = DateGrouping.group(for: date(2026, 8, 20), now: now, calendar: calendar)
        XCTAssertEqual(group.title, date(2026, 8, 20).formatted(.dateTime.day().month(.abbreviated)))
    }

    func testFutureDatesFallBackToDayMonthFormat() {
        let group = DateGrouping.group(for: date(2026, 8, 31), now: now, calendar: calendar)
        XCTAssertEqual(group.title, "31 Aug")
    }

    func testGroupsDeduplicateAndKeepNewestFirstOrder() {
        let dates = [
            date(2026, 8, 30),
            date(2026, 8, 30, hour: 8),
            date(2026, 8, 29),
            date(2026, 8, 30, hour: 20),
            date(2026, 8, 20),
        ]
        let groups = DateGrouping.groups(for: dates, now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday", "20 Aug"])
    }

    func testKeysAreStablePerDay() {
        let a = DateGrouping.group(for: date(2026, 8, 30, hour: 3), now: now, calendar: calendar)
        let b = DateGrouping.group(for: date(2026, 8, 30, hour: 23), now: now, calendar: calendar)
        XCTAssertEqual(a.key, b.key)
    }
}
