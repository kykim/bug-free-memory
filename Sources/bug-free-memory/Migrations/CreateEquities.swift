//
//  CreateEquities.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent

struct CreateEquities: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("equities")
            .field("instrument_id", .uuid, .required, .identifier(auto: false),
                   .references("instruments", "id", onDelete: .cascade))
            .field("isin", .string)
            .field("cusip", .string)
            .field("figi", .string)
            .field("sector", .string)
            .field("industry", .string)
            .field("shares_outstanding", .int64)
            .unique(on: "isin")
            .unique(on: "cusip")
            .unique(on: "figi")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("equities").delete()
    }
}
