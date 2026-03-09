//
//  CreateEODPrices.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import FluentSQL

struct CreateEODPrices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("eod_prices")
            .field("id", .uuid, .required, .identifier(auto: false))
            .field("instrument_id", .uuid, .required,
                   .references("instruments", "id", onDelete: .cascade))
            .field("price_date", .date, .required)
            .field("open", .double)
            .field("high", .double)
            .field("low", .double)
            .field("close", .double, .required)
            .field("adj_close", .double)
            .field("volume", .int64)
            .field("vwap", .double)
            .field("source", .string)
            .field("created_at", .datetime)
            .unique(on: "instrument_id", "price_date")
            .create()

        try await (database as! any SQLDatabase).raw("""
            CREATE INDEX idx_eod_prices_instrument_date
            ON eod_prices (instrument_id, price_date DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("eod_prices").delete()
    }
}
