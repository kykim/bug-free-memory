//
//  CreateOAuthToken.swift
//  hello
//
//  Created by Kevin Y Kim on 3/12/26.
//


import Fluent

struct CreateOAuthToken: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(OAuthToken.schema)
            .id()
            .field("clerk_user_id", .string, .required)
            .field("provider", .string, .required)
            .field("access_token", .string, .required)
            .field("refresh_token", .string)
            .field("scope", .string)
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            // One active token per user per provider
            .unique(on: "clerk_user_id", "provider")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(OAuthToken.schema).delete()
    }
}
