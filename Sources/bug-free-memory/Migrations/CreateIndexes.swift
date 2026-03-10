//
//  CreateIndexes.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent

struct CreateIndexes: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("indexes")
            .field("instrument_id", .uuid, .required, .identifier(auto: false),
                   .references("instruments", "id", onDelete: .cascade))
            .field("index_family", .string)
            .field("methodology", .string)
            .field("rebalance_freq", .string)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("indexes").delete()
    }
}
