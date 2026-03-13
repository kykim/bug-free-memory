//
//  MarketHoliday.swift
//  bug-free-memory
//
//  Stores US market holidays. Populated by CreateMarketHolidays migration
//  and manageable at runtime via MarketCalendar helpers.
//

import Fluent
import Vapor

final class MarketHoliday: Model, Content, @unchecked Sendable {
    static let schema = "market_holidays"

    @ID
    var id: UUID?

    /// The market holiday date (DATE, stored as midnight America/New_York).
    @Field(key: "holiday_date")
    var holidayDate: Date

    /// Human-readable label (e.g. "New Year's Day").
    @OptionalField(key: "description")
    var description: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, holidayDate: Date, description: String? = nil) {
        self.id = id
        self.holidayDate = holidayDate
        self.description = description
    }
}
