//
//  CreateMarketHolidays.swift
//  bug-free-memory
//
//  Creates the market_holidays table and seeds the 2026 US market holiday schedule.
//

import Fluent
import Foundation

struct CreateMarketHolidays: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema(MarketHoliday.schema)
            .id()
            .field("holiday_date", .date,   .required)
            .field("description",  .string)
            .field("created_at",   .datetime)
            .unique(on: "holiday_date")
            .create()

        // Seed 2026 US market holidays
        let holidays2026: [(month: Int, day: Int, description: String)] = [
            (1,  1,  "New Year's Day"),
            (1,  19, "Martin Luther King Jr. Day"),
            (2,  16, "Presidents' Day"),
            (4,  3,  "Good Friday"),
            (5,  25, "Memorial Day"),
            (7,  3,  "Independence Day (observed)"),
            (9,  7,  "Labor Day"),
            (11, 26, "Thanksgiving Day"),
            (12, 25, "Christmas Day"),
        ]

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!

        for h in holidays2026 {
            let date = cal.date(from: DateComponents(year: 2026, month: h.month, day: h.day))!
            try await MarketHoliday(holidayDate: date, description: h.description).save(on: database)
        }
    }

    func revert(on database: any Database) async throws {
        try await database.schema(MarketHoliday.schema).delete()
    }
}
