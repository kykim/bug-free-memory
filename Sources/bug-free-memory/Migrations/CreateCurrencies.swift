//
//  CreateCurrencies.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent

struct CreateCurrencies: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("currencies")
            .field("currency_code", .string, .identifier(auto: false))
            .field("name", .string, .required)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("currencies").delete()
    }
}
