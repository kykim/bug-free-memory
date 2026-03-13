//
//  MarketCalendarTests.swift
//  bug-free-memory
//
//  TICKET-005: MarketCalendar unit + integration tests.
//  Pure helpers (isWeekend, startOfDay) run without a DB.
//  DB-backed tests use an in-memory SQLite database with the
//  CreateMarketHolidays migration applied.
//

import Testing
import Foundation
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import bug_free_memory

// MARK: - Helpers

private func makeNYDate(year: Int, month: Int, day: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.date(from: DateComponents(year: year, month: month, day: day))!
}

/// Boots an in-memory SQLite app, runs CreateMarketHolidays, calls `body`, then tears down.
private func withHolidayDB(_ body: (any Database) async throws -> Void) async throws {
    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateMarketHolidays())
        try await app.autoMigrate()
    }) { app in
        try await body(app.db)
    }
}

// MARK: - Pure helper tests (no DB)

@Suite("MarketCalendar — pure helpers")
struct MarketCalendarPureTests {

    @Test("startOfDay strips time component")
    func startOfDayStripsTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let input = cal.date(from: DateComponents(year: 2026, month: 3, day: 13, hour: 14, minute: 30))!
        let result = MarketCalendar.startOfDay(input)
        let comps = cal.dateComponents([.hour, .minute, .second], from: result)
        #expect(comps.hour == 0 && comps.minute == 0 && comps.second == 0)
    }

    @Test("isWeekend returns true for Saturday")
    func saturday() {
        #expect(MarketCalendar.isWeekend(makeNYDate(year: 2026, month: 3, day: 14)))
    }

    @Test("isWeekend returns true for Sunday")
    func sunday() {
        #expect(MarketCalendar.isWeekend(makeNYDate(year: 2026, month: 3, day: 15)))
    }

    @Test("isWeekend returns false for each weekday Mon–Fri")
    func weekdays() {
        for day in 9...13 {   // Mon 9 Mar – Fri 13 Mar 2026
            #expect(!MarketCalendar.isWeekend(makeNYDate(year: 2026, month: 3, day: day)))
        }
    }
}

// MARK: - DB-backed tests

@Suite("MarketCalendar — DB-backed")
struct MarketCalendarDBTests {

    // MARK: isHoliday

    @Test("isHoliday returns true for all 9 seeded 2026 holidays")
    func seededHolidaysAreRecognised() async throws {
        let holidays: [(Int, Int)] = [
            (1, 1), (1, 19), (2, 16), (4, 3),
            (5, 25), (7, 3), (9, 7), (11, 26), (12, 25)
        ]
        try await withHolidayDB { db in
            for (month, day) in holidays {
                let date = makeNYDate(year: 2026, month: month, day: day)
                let result = try await MarketCalendar.isHoliday(date, db: db)
                #expect(result, "Expected \(month)/\(day)/2026 to be a holiday")
            }
        }
    }

    @Test("isHoliday returns false for a normal trading day")
    func normalDayNotHoliday() async throws {
        try await withHolidayDB { db in
            let friday = makeNYDate(year: 2026, month: 3, day: 13)
            let result = try await MarketCalendar.isHoliday(friday, db: db)
            #expect(!result)
        }
    }

    @Test("isHoliday matches regardless of time-of-day")
    func holidayMatchesWithNonMidnightTime() async throws {
        try await withHolidayDB { db in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "America/New_York")!
            let xmasAfternoon = cal.date(from: DateComponents(year: 2026, month: 12, day: 25, hour: 15))!
            let result = try await MarketCalendar.isHoliday(xmasAfternoon, db: db)
            #expect(result)
        }
    }

    // MARK: isTradingDay

    @Test("isTradingDay returns false on a Saturday")
    func weekendNotTradingDay() async throws {
        try await withHolidayDB { db in
            let sat = makeNYDate(year: 2026, month: 3, day: 14)
            let result = try await MarketCalendar.isTradingDay(sat, db: db)
            #expect(!result)
        }
    }

    @Test("isTradingDay returns false on a holiday")
    func holidayNotTradingDay() async throws {
        try await withHolidayDB { db in
            let thanksgiving = makeNYDate(year: 2026, month: 11, day: 26)
            let result = try await MarketCalendar.isTradingDay(thanksgiving, db: db)
            #expect(!result)
        }
    }

    @Test("isTradingDay returns true for a normal weekday")
    func normalWeekdayIsTradingDay() async throws {
        try await withHolidayDB { db in
            let friday = makeNYDate(year: 2026, month: 3, day: 13)
            let result = try await MarketCalendar.isTradingDay(friday, db: db)
            #expect(result)
        }
    }

    // MARK: addHoliday / removeHoliday

    @Test("addHoliday inserts; removeHoliday deletes")
    func addAndRemove() async throws {
        try await withHolidayDB { db in
            let juneteenth = makeNYDate(year: 2026, month: 6, day: 19)

            let before = try await MarketCalendar.isHoliday(juneteenth, db: db)
            #expect(!before)

            try await MarketCalendar.addHoliday(juneteenth, description: "Juneteenth", db: db)
            let after = try await MarketCalendar.isHoliday(juneteenth, db: db)
            #expect(after)

            try await MarketCalendar.removeHoliday(juneteenth, db: db)
            let removed = try await MarketCalendar.isHoliday(juneteenth, db: db)
            #expect(!removed)
        }
    }

    @Test("removeHoliday on non-existent date is a no-op")
    func removeNonExistent() async throws {
        try await withHolidayDB { db in
            let randomDay = makeNYDate(year: 2026, month: 8, day: 3)
            // Should not throw
            try await MarketCalendar.removeHoliday(randomDay, db: db)
        }
    }

    // MARK: holidays(in:db:)

    @Test("holidays(in:) returns all 9 seeded 2026 holidays sorted ascending")
    func holidaysInYear() async throws {
        try await withHolidayDB { db in
            let list = try await MarketCalendar.holidays(in: 2026, db: db)
            #expect(list.count == 9)
            for i in 0..<(list.count - 1) {
                #expect(list[i].holidayDate <= list[i + 1].holidayDate)
            }
        }
    }

    @Test("holidays(in:) returns empty for a year with no records")
    func holidaysInEmptyYear() async throws {
        try await withHolidayDB { db in
            let list = try await MarketCalendar.holidays(in: 2025, db: db)
            #expect(list.isEmpty)
        }
    }
}
