//
//  CreateJobRuns.swift
//  bug-free-memory
//

import Fluent
import FluentSQL

struct CreateJobRuns: AsyncMigration {

    func prepare(on database: any Database) async throws {
        try await database.schema("job_runs")
            .id()
            .field("run_date",          .date,    .required)
            .field("status",            .string,  .required)
            .field("equities_fetched",  .int)
            .field("options_fetched",   .int)
            .field("contracts_priced",  .int)
            .field("theoretical_rows",  .int)
            .field("new_contracts",     .int)
            .field("dropped_positions", .array(of: .string))
            .field("failed_tickers",    .array(of: .string))
            .field("skipped_contracts", .array(of: .string))
            .field("failed_contracts",  .array(of: .uuid))
            .field("error_messages",    .array(of: .string))
            .field("source_used",       .string)
            .field("started_at",        .datetime, .required)
            .field("completed_at",      .datetime)
            .unique(on: "run_date")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("job_runs").delete()
    }
}
