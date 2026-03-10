import Fluent

struct CreateInstruments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        // Create the enum type in Postgres
        let instrumentTypeEnum = try await database.enum("instrument_type")
            .case("equity")
            .case("index")
            .case("equity_option")
            .case("index_option")
            .create()

        try await database.schema("instruments")
            .field("id", .uuid, .required, .identifier(auto: false))
            .field("instrument_type", instrumentTypeEnum, .required)
            .field("ticker", .string, .required)
            .field("name", .string, .required)
            .field("exchange_id", .uuid, .references("exchanges", "id", onDelete: .setNull))
            .field("currency_code", .string, .required, .references("currencies", "currency_code"))
            .field("is_active", .bool, .required, .sql(.default(true)))
            .field("created_at", .datetime)
            .unique(on: "ticker", "exchange_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("instruments").delete()
        try await database.enum("instrument_type").delete()
    }
}
