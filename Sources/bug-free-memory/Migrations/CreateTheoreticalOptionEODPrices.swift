//
//  CreateTheoreticalOptionEODPrices.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Fluent
import FluentSQL

struct CreateTheoreticalOptionEODPrice: AsyncMigration {

    func prepare(on database: any Database) async throws {
        // Ensure the enum type exists in Postgres first
        let pricingModelEnum = try await database.enum("pricing_model")
            .case("black_scholes")
            .case("binomial")
            .case("monte_carlo")
            .create()

        try await database.schema(TheoreticalOptionEODPrice.schema)
            .id()
            .field("instrument_id",        .uuid,    .required,
                   .references("instruments", "id", onDelete: .cascade))
            .field("price_date",           .date,    .required)
            .field("price",                .double,  .required)
            .field("settlement_price",     .double)
            .field("implied_volatility",   .double)
            .field("historical_volatility",.double,  .required)
            .field("risk_free_rate",       .double,  .required)
            .field("underlying_price",     .double,  .required)
            .field("delta",                .double)
            .field("gamma",                .double)
            .field("theta",                .double)
            .field("vega",                 .double)
            .field("rho",                  .double)
            .field("model",                pricingModelEnum, .required)
            .field("model_detail",         .string)
            .field("source",               .string)
            .field("created_at",           .datetime)
            // One theoretical price per instrument per date per model
            .unique(on: "instrument_id", "price_date", "model")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(TheoreticalOptionEODPrice.schema).delete()
        try await database.enum("pricing_model").delete()
    }
}

