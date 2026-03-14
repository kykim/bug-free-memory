//
//  RunLogActivityTests.swift
//  bug-free-memory
//
//  TICKET-014: RunLogActivity integration tests.
//  Uses in-memory SQLite + a SQLite-compatible job_runs migration.
//
//  NOTE: CreateJobRuns uses .array(of:) columns which are PostgreSQL-specific.
//  The test migration below uses .string for those fields so the suite
//  runs on SQLite.
//

import Testing
import Foundation
import Logging
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import bug_free_memory

// MARK: - SQLite-compatible job_runs migration (no array columns)

struct TestCreateJobRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("job_runs")
            .field("id", .uuid, .required, .identifier(auto: false))
            .field("run_date", .date, .required)
            .field("status", .string, .required)
            .field("equities_fetched", .int)
            .field("options_fetched", .int)
            .field("contracts_priced", .int)
            .field("theoretical_rows", .int)
            .field("new_contracts", .int)
            .field("dropped_positions", .string)
            .field("failed_tickers", .string)
            .field("skipped_contracts", .string)
            .field("failed_contracts", .string)
            .field("error_messages", .string)
            .field("source_used", .string)
            .field("started_at", .datetime, .required)
            .field("completed_at", .datetime)
            .unique(on: "run_date")
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema("job_runs").delete()
    }
}

// MARK: - DB helper

private func withRunLogDB(_ body: (any Database) async throws -> Void) async throws {
    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(TestCreateJobRuns())
        try await app.autoMigrate()
    }) { app in
        try await body(app.db)
    }
}

// MARK: - Input builders

private func minimalInput(
    runDate: Date = Date(),
    status: RunStatus = .success,
    errorMessages: [String] = [],
    startedAt: Date = Date().addingTimeInterval(-5)
) -> RunLogInput {
    RunLogInput(
        runDate: runDate,
        status: status,
        portfolioResult: nil,
        eodResult: nil,
        indexEODResult: nil,
        optionEODResult: nil,
        pricingResult: nil,
        errorMessages: errorMessages,
        startedAt: startedAt,
        completedAt: Date()
    )
}

// MARK: - Tests

@Suite("RunLogActivity", .serialized)
struct RunLogActivityTests {

    @Test("writeRunLog inserts a row with correct status")
    func insertsRow() async throws {
        try await withRunLogDB { db in
            let activity = RunLogActivities(db: db, logger: Logger(label: "test"))
            try await activity.writeRunLog(input: minimalInput(status: .success))

            let rows = try await JobRun.query(on: db).all()
            #expect(rows.count == 1)
            #expect(rows[0].status == "success")
        }
    }

    @Test("Upsert updates status but preserves started_at")
    func upsertPreservesStartedAt() async throws {
        try await withRunLogDB { db in
            let activity = RunLogActivities(db: db, logger: Logger(label: "test"))
            let runDate = Date()
            let originalStart = Date().addingTimeInterval(-10)

            try await activity.writeRunLog(input: RunLogInput(
                runDate: runDate, status: .success,
                portfolioResult: nil, eodResult: nil, indexEODResult: nil, optionEODResult: nil, pricingResult: nil,
                errorMessages: [], startedAt: originalStart, completedAt: Date()
            ))

            try await activity.writeRunLog(input: RunLogInput(
                runDate: runDate, status: .partial,
                portfolioResult: nil, eodResult: nil, indexEODResult: nil, optionEODResult: nil, pricingResult: nil,
                errorMessages: ["something failed"], startedAt: Date(), completedAt: Date()
            ))

            let rows = try await JobRun.query(on: db).all()
            #expect(rows.count == 1)
            #expect(rows[0].status == "partial")
            // started_at is preserved from original insert (within 1s tolerance)
            #expect(abs(rows[0].startedAt.timeIntervalSince(originalStart)) < 1.0)
        }
    }

    @Test("failed status is written correctly")
    func failedStatus() async throws {
        try await withRunLogDB { db in
            let activity = RunLogActivities(db: db, logger: Logger(label: "test"))
            try await activity.writeRunLog(input: minimalInput(status: .failed, errorMessages: ["fatal error"]))

            let row = try await JobRun.query(on: db).first()!
            #expect(row.status == "failed")
        }
    }

    @Test("skipped status is written correctly")
    func skippedStatus() async throws {
        try await withRunLogDB { db in
            let activity = RunLogActivities(db: db, logger: Logger(label: "test"))
            try await activity.writeRunLog(input: minimalInput(status: .skipped))

            let row = try await JobRun.query(on: db).first()!
            #expect(row.status == "skipped")
        }
    }
}

// MARK: - RunStatus.determine unit tests

@Suite("RunStatus.determine")
struct RunStatusDetermineTests {

    @Test("forceSkipped always returns .skipped")
    func forceSkipped() {
        let status = RunStatus.determine(
            portfolioResult: nil, eodResult: nil, optionEODResult: nil, pricingResult: nil,
            errorMessages: ["some error"], forceSkipped: true)
        #expect(status == .skipped)
    }

    @Test("No errors → success")
    func noErrors() {
        let status = RunStatus.determine(
            portfolioResult: nil, eodResult: nil, optionEODResult: nil, pricingResult: nil,
            errorMessages: [])
        #expect(status == .success)
    }

    @Test("Errors with no portfolio and no optionEOD → failed")
    func errorsNoResults() {
        let status = RunStatus.determine(
            portfolioResult: nil, eodResult: nil, optionEODResult: nil, pricingResult: nil,
            errorMessages: ["portfolio fetch failed"])
        #expect(status == .failed)
    }

    @Test("Errors with portfolio present → partial")
    func errorsWithPortfolio() {
        let portfolio = FilteredPositionSet(
            equityInstrumentIDs: [], optionInstrumentIDs: [],
            newContractsRegistered: 0, droppedPositions: [], runDate: Date())
        let status = RunStatus.determine(
            portfolioResult: portfolio, eodResult: nil, optionEODResult: nil, pricingResult: nil,
            errorMessages: ["eod failed"])
        #expect(status == .partial)
    }

    @Test("Errors with optionEOD present → partial")
    func errorsWithOptionEOD() {
        let optionEOD = OptionEODResult(contractsProcessed: 1, rowsUpserted: 1, skippedContracts: [])
        let status = RunStatus.determine(
            portfolioResult: nil, eodResult: nil, optionEODResult: optionEOD, pricingResult: nil,
            errorMessages: ["pricing failed"])
        #expect(status == .partial)
    }
}
