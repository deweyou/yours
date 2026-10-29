import Foundation
import Testing

@testable import Yours

struct TodoCalendarTests {
    private func calendar(_ zone: String = "Asia/Shanghai", firstWeekday: Int = 2) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, calendar: Calendar) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    @Test(arguments: [(2026, 10, 35), (2021, 2, 28), (2026, 8, 42), (2024, 2, 35)])
    func monthContainsEveryDayInWholeWeeks(_ year: Int, _ month: Int, _ cellCount: Int) throws {
        let calendar = try calendar()
        let selected = try date(year, month, 15, calendar: calendar)
        let grid = TodoCalendarMonth(containing: selected, calendar: calendar)
        #expect(grid.days.count == cellCount)
        let first = try #require(grid.days.first)
        #expect(calendar.component(.weekday, from: first) == calendar.firstWeekday)
        let actualDays = grid.days.filter { calendar.isDate($0, equalTo: selected, toGranularity: .month) }
            .map { calendar.component(.day, from: $0) }
        let range = try #require(calendar.range(of: .day, in: .month, for: selected))
        #expect(actualDays == Array(range))
        #expect(Set(grid.days).count == grid.days.count)
    }

    @Test func adjacentYearCellsAndCustomWeekStartRemainCorrect() throws {
        let calendar = try calendar(firstWeekday: 1)
        let grid = TodoCalendarMonth(containing: try date(2026, 1, 15, calendar: calendar), calendar: calendar)
        let first = try #require(grid.days.first)
        #expect(first == (try date(2025, 12, 28, calendar: calendar)))
        #expect(calendar.component(.weekday, from: first) == 1)
        #expect(grid.days.contains(try date(2026, 1, 31, calendar: calendar)))
    }

    @Test func dateSelectionPreservesClockOnLeapDayAndDSTBoundary() throws {
        let calendar = try calendar("America/Los_Angeles")
        let original = try date(2024, 2, 28, hour: 10, minute: 45, calendar: calendar)
        for day in [try date(2024, 2, 29, calendar: calendar), try date(2024, 3, 10, calendar: calendar)] {
            let selected = TodoCalendarMonth.selecting(day, preservingTimeOf: original, calendar: calendar)
            #expect(calendar.isDate(selected, inSameDayAs: day))
            #expect(calendar.component(.hour, from: selected) == 10)
            #expect(calendar.component(.minute, from: selected) == 45)
        }
        let grid = TodoCalendarMonth(containing: try date(2024, 3, 15, calendar: calendar), calendar: calendar)
        for pair in zip(grid.days, grid.days.dropFirst()) {
            #expect(calendar.dateComponents([.day], from: pair.0, to: pair.1).day == 1)
        }
    }
    @Test func twoClicksSelectAcrossYearAndNextClickStartsNewRange() throws {
        let calendar = try calendar()
        var start = try date(2026, 10, 28, hour: 9, minute: 15, calendar: calendar)
        var end = try date(2026, 10, 28, hour: 10, minute: 45, calendar: calendar)
        var selection = TodoCalendarRangeSelection()
        selection.select(try date(2026, 12, 30, calendar: calendar), start: &start, end: &end, calendar: calendar)
        #expect(selection.anchor != nil)
        #expect(start == (try date(2026, 12, 30, hour: 9, minute: 15, calendar: calendar)))
        selection.select(try date(2027, 1, 3, calendar: calendar), start: &start, end: &end, calendar: calendar)
        #expect(selection.anchor == nil)
        #expect(end == (try date(2027, 1, 3, hour: 10, minute: 45, calendar: calendar)))
        selection.select(try date(2027, 2, 1, calendar: calendar), start: &start, end: &end, calendar: calendar)
        #expect(selection.anchor != nil)
        #expect(calendar.isDate(start, inSameDayAs: end))
    }

    @Test func earlierSecondClickRestartsAnchorAndSameDayEndIsValid() throws {
        let calendar = try calendar()
        var start = try date(2026, 10, 28, hour: 23, minute: 59, calendar: calendar)
        var end = try date(2026, 10, 29, hour: 0, calendar: calendar)
        var selection = TodoCalendarRangeSelection()
        selection.select(try date(2026, 10, 30, calendar: calendar), start: &start, end: &end, calendar: calendar)
        selection.select(try date(2026, 10, 29, calendar: calendar), start: &start, end: &end, calendar: calendar)
        #expect(selection.anchor == (try date(2026, 10, 29, calendar: calendar)))
        selection.select(try date(2026, 10, 29, calendar: calendar), start: &start, end: &end, calendar: calendar)
        #expect(selection.anchor == nil)
        #expect(end.timeIntervalSince(start) == 60)
    }

    @Test func switchingDateFieldsKeepsUnfinishedRangeAndInspectingEndDoesNotRequireChanges() throws {
        let calendar = try calendar()
        var start = try date(2026, 10, 28, hour: 9, calendar: calendar)
        var end = try date(2026, 10, 30, hour: 10, calendar: calendar)
        var selection = TodoCalendarRangeSelection()
        selection.prepareToSelectEnd(start: start)
        #expect(selection.isIncomplete == false)
        selection.prepareToSelectStart()
        selection.select(try date(2026, 11, 2, calendar: calendar), start: &start, end: &end, calendar: calendar)
        #expect(selection.isIncomplete)
        let anchor = selection.anchor
        selection.prepareToSelectEnd(start: start)
        selection.prepareToSelectStart()
        #expect(selection.anchor == anchor)
        #expect(selection.isIncomplete)
        selection.select(try date(2026, 11, 5, calendar: calendar), start: &start, end: &end, calendar: calendar)
        #expect(selection.isIncomplete == false)
        #expect(end == (try date(2026, 11, 5, hour: 10, calendar: calendar)))
    }

}
