//
//  RunLogActivity.swift
//  bug-free-memory
//
//  Temporal activity that writes (or upserts) the job_runs record.
//  Always executes, even if upstream activities failed.
//  Preserves started_at from the original insert on conflict.
//

import Fluent
import FluentSQL
import Foundation
import Logging
import Temporal

@ActivityContainer
public struct RunLogActivities {

    private let db: any Database
    private let logger: Logger

    public init(db: any Database, logger: Logger) {
        self.db = db
        self.logger = logger
    }

    @Activity(
        retryPolicy: RetryPolicy(
            initialInterval: .seconds(5),
            backoffCoefficient: 1.5,
            maximumAttempts: 5
        ),
        scheduleToCloseTimeout: .seconds(60)
    )
    public func writeRunLog(input: RunLogInput) async throws {
        let completedAt = Date()

        // Derive human-readable array fields
        let droppedPositionsStrings: [String] = input.portfolioResult?.droppedPositions
            .map { "\($0.ticker): \($0.reason)" } ?? []

        let skippedContractStrings: [String] = input.optionEODResult?.skippedContracts
            .map { $0.osiSymbol ?? "\($0.instrumentID)" } ?? []

        let failedContractIDs: [UUID] = input.pricingResult?.failedContracts
            .map { $0.instrumentID } ?? []

        let sqlDB = db as! any SQLDatabase
        let newID = UUID()
        let runDateOnly = Calendar.utcCal.startOfDay(for: input.runDate)

        try await sqlDB.raw("""
            INSERT INTO job_runs
                (id, run_date, status,
                 equities_fetched, options_fetched, contracts_priced, theoretical_rows, new_contracts,
                 dropped_positions, failed_tickers, skipped_contracts, failed_contracts, error_messages,
                 source_used, started_at, completed_at)
            VALUES
                (\(bind: newID), \(bind: runDateOnly), \(bind: input.status.rawValue),
                 \(bind: input.portfolioResult?.equityInstrumentIDs.count),
                 \(bind: input.portfolioResult?.optionInstrumentIDs.count),
                 \(bind: input.pricingResult?.contractsPriced),
                 \(bind: input.pricingResult?.rowsUpserted),
                 \(bind: input.portfolioResult?.newContractsRegistered),
                 \(bind: droppedPositionsStrings),
                 \(bind: input.eodResult?.failedTickers ?? []),
                 \(bind: skippedContractStrings),
                 \(bind: failedContractIDs),
                 \(bind: input.errorMessages),
                 \(bind: input.eodResult?.source),
                 \(bind: input.startedAt), \(bind: completedAt))
            ON CONFLICT (run_date) DO UPDATE SET
                status            = EXCLUDED.status,
                equities_fetched  = EXCLUDED.equities_fetched,
                options_fetched   = EXCLUDED.options_fetched,
                contracts_priced  = EXCLUDED.contracts_priced,
                theoretical_rows  = EXCLUDED.theoretical_rows,
                new_contracts     = EXCLUDED.new_contracts,
                dropped_positions = EXCLUDED.dropped_positions,
                failed_tickers    = EXCLUDED.failed_tickers,
                skipped_contracts = EXCLUDED.skipped_contracts,
                failed_contracts  = EXCLUDED.failed_contracts,
                error_messages    = EXCLUDED.error_messages,
                source_used       = EXCLUDED.source_used,
                completed_at      = EXCLUDED.completed_at
            """).run()
        // Note: started_at is intentionally excluded from DO UPDATE to preserve original value.

        let duration = completedAt.timeIntervalSince(input.startedAt)
        logger.info("[RunLogActivity] wrote run log — runDate=\(input.runDate) status=\(input.status.rawValue) duration=\(String(format: "%.2f", duration))s")
    }
}

private extension Calendar {
    static let utcCal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
