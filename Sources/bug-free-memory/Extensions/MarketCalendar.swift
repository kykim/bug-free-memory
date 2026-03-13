//
//  MarketCalendar.swift
//  bug-free-memory
//
//  US market calendar backed by the market_holidays database table.
//  Weekend detection is pure (no DB); holiday checks are async.
//

import Fluent
import Foundation

enum MarketCalendar {

    private static var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    // MARK: - Pure helpers

    /// Normalises `date` to midnight America/New_York — used before any DB comparison.
    static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Returns `true` for Saturday or Sunday (America/New_York).
    static func isWeekend(_ date: Date) -> Bool {
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7   // 1 = Sunday, 7 = Saturday
    }

    // MARK: - DB-backed checks

    /// Returns `true` when `date` is a recorded market holiday.
    static func isHoliday(_ date: Date, db: any Database) async throws -> Bool {
        let day = startOfDay(date)
        return try await MarketHoliday.query(on: db)
            .filter(\.$holidayDate == day)
            .count() > 0
    }

    /// Returns `true` when the market is open on `date` (not a weekend, not a holiday).
    static func isTradingDay(_ date: Date, db: any Database) async throws -> Bool {
        guard !isWeekend(date) else { return false }
        return try await !isHoliday(date, db: db)
    }

    // MARK: - Management

    /// Inserts a new holiday record. Throws if the date already exists (UNIQUE constraint).
    static func addHoliday(_ date: Date, description: String? = nil, db: any Database) async throws {
        let holiday = MarketHoliday(holidayDate: startOfDay(date), description: description)
        try await holiday.save(on: db)
    }

    /// Deletes the holiday record for `date`, if any.
    static func removeHoliday(_ date: Date, db: any Database) async throws {
        let day = startOfDay(date)
        try await MarketHoliday.query(on: db)
            .filter(\.$holidayDate == day)
            .delete()
    }

    /// Returns all holidays for a given calendar year, sorted ascending.
    static func holidays(in year: Int, db: any Database) async throws -> [MarketHoliday] {
        let start = calendar.date(from: DateComponents(year: year,     month: 1, day: 1))!
        let end   = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))!
        return try await MarketHoliday.query(on: db)
            .filter(\.$holidayDate >= start)
            .filter(\.$holidayDate < end)
            .sort(\.$holidayDate)
            .all()
    }
}
