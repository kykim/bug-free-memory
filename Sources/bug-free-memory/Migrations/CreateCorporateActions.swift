//
//  CreateCorporateActions.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent

struct CreateCorporateActions: AsyncMigration {
    func prepare(on database: any Database) async throws {
        let actionTypeEnum = try await database.enum("corporate_action_type")
            .case("split")
            .case("reverse_split")
            .case("dividend_cash")
            .case("dividend_stock")
            .case("spinoff")
            .case("merger")
            .case("delisting")
            .create()

        try await database.schema("corporate_actions")
            .field("id", .uuid, .required, .identifier(auto: false))
            .field("instrument_id", .uuid, .required,
                   .references("instruments", "id", onDelete: .cascade))
            .field("action_type", actionTypeEnum, .required)
            .field("ex_date", .date, .required)
            .field("record_date", .date)
            .field("pay_date", .date)
            .field("ratio", .double)
            .field("notes", .string)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("corporate_actions").delete()
        try await database.enum("corporate_action_type").delete()
    }
}
