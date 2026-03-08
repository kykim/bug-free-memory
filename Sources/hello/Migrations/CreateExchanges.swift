//
//  CreateExchanges.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent

struct CreateExchanges: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("exchanges")
            .field("exchange_id", .int, .identifier(auto: true))
            .field("mic_code", .string, .required)
            .field("name", .string, .required)
            .field("country_code", .string, .required)
            .field("timezone", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "mic_code")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("exchanges").delete()
    }
}
