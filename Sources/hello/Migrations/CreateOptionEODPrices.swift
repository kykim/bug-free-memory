//
//  CreateOptionEODPrices.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import FluentSQL

struct CreateOptionEODPrices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("option_eod_prices")
            .field("option_eod_id", .int, .identifier(auto: true))
            .field("instrument_id", .int, .required,
                   .references("instruments", "instrument_id", onDelete: .cascade))
            .field("price_date", .date, .required)
            .field("bid", .double)
            .field("ask", .double)
            // mid is a generated column — created via raw SQL below
            .field("last", .double)
            .field("settlement_price", .double)
            .field("volume", .int64)
            .field("open_interest", .int64)
            .field("implied_volatility", .double)
            .field("delta", .double)
            .field("gamma", .double)
            .field("theta", .double)
            .field("vega", .double)
            .field("rho", .double)
            .field("underlying_price", .double)
            .field("risk_free_rate", .double)
            .field("dividend_yield", .double)
            .field("source", .string)
            .field("created_at", .datetime)
            .unique(on: "instrument_id", "price_date")
            .create()

        // Add the generated column after table creation
        try await (database as! any SQLDatabase).raw("""
            ALTER TABLE option_eod_prices
            ADD COLUMN mid DOUBLE PRECISION GENERATED ALWAYS AS ((bid + ask) / 2) STORED
            """).run()

        try await (database as! any SQLDatabase).raw("""
            CREATE INDEX idx_option_eod_instrument_date
            ON option_eod_prices (instrument_id, price_date DESC)
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("option_eod_prices").delete()
    }
}
