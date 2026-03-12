//
//  CreateFREDYield.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Fluent


struct CreateFREDYield: AsyncMigration {

    func prepare(on database: any Database) async throws {
        let seriesEnum = try await database.enum("fred_series")
            .case("DGS1MO")
            .case("DGS3MO")
            .case("DGS6MO")
            .case("DGS1")
            .case("DGS2")
            .case("DGS5")
            .create()

        try await database.schema(FREDYield.schema)
            .id()
            .field("series_id",        seriesEnum, .required)
            .field("observation_date", .date,      .required)
            .field("yield_percent",    .double)
            .field("continuous_rate",  .double)
            .field("tenor_years",      .double,    .required)
            .field("source",           .string)
            .field("created_at",       .datetime)
            .field("updated_at",       .datetime)
            // One observation per series per date
            .unique(on: "series_id", "observation_date")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema(FREDYield.schema).delete()
        try await database.enum("fred_series").delete()
    }
}
