//
//  CreateOptionContracts.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import FluentSQL

struct CreateOptionContracts: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let optionTypeEnum = try await database.enum("option_type")
            .case("call")
            .case("put")
            .create()

        let exerciseStyleEnum = try await database.enum("exercise_style")
            .case("american")
            .case("european")
            .case("bermudan")
            .create()

        try await database.schema("option_contracts")
            .field("instrument_id", .uuid, .identifier(auto: false),
                   .references("instruments", "id", onDelete: .cascade))
            .field("underlying_id", .uuid, .required,
                   .references("instruments", "id"))
            .field("option_type", optionTypeEnum, .required)
            .field("exercise_style", exerciseStyleEnum, .required)
            .field("strike_price", .double, .required)
            .field("expiration_date", .date, .required)
            .field("contract_multiplier", .double, .required, .sql(.default(100)))
            .field("settlement_type", .string, .required, .sql(.default("physical")))
            .field("osi_symbol", .string)
            .unique(on: "osi_symbol")
            .create()

        // Index for option chain lookups
        try await (database as! any SQLDatabase).raw("""
            CREATE INDEX idx_option_contracts_underlying
            ON option_contracts (underlying_id, expiration_date, strike_price)
            """).run()

        try await (database as! any SQLDatabase).raw("""
            CREATE INDEX idx_option_contracts_expiry
            ON option_contracts (expiration_date)
            """).run()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("option_contracts").delete()
        try await database.enum("option_type").delete()
        try await database.enum("exercise_style").delete()
    }
}
