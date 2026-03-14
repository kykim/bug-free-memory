//
//  RunLogActivity.swift
//  bug-free-memory
//
//  Temporal activity that writes (or upserts) the job_runs record.
//  Always executes, even if upstream activities failed.
//  Preserves started_at from the original insert on conflict.
//

import Fluent
import Foundation
import Logging
import Temporal

@ActivityContainer
struct RunLogActivities {

    private let db: any Database
    private let logger: Logger

    init(db: any Database, logger: Logger) {
        self.db = db
        self.logger = logger
    }

    @Activity
    func writeRunLog(input: RunLogInput) async throws {
        let completedAt = Date()

        // Derive human-readable array fields
        let droppedPositionsStrings: [String] = input.portfolioResult?.droppedPositions
            .map { "\($0.ticker): \($0.reason)" } ?? []

        let skippedContractStrings: [String] = input.optionEODResult?.skippedContracts
            .map { $0.osiSymbol ?? "\($0.instrumentID)" } ?? []

        let failedContractIDs: [UUID] = input.pricingResult?.failedContracts
            .map { $0.instrumentID } ?? []

        let runDateOnly = Calendar.utc.startOfDay(for: input.runDate)

        if let existing = try await JobRun.query(on: db)
            .filter(\.$runDate == runDateOnly)
            .first() {
            // started_at is intentionally not updated — preserve the original value
            existing.status           = input.status.rawValue
            existing.equitiesFetched  = input.portfolioResult?.equityInstrumentIDs.count
            existing.optionsFetched   = input.portfolioResult?.optionInstrumentIDs.count
            existing.contractsPriced  = input.pricingResult?.contractsPriced
            existing.theoreticalRows  = input.pricingResult?.rowsUpserted
            existing.newContracts     = input.portfolioResult?.newContractsRegistered
            existing.droppedPositions = droppedPositionsStrings
            existing.failedTickers    = input.eodResult?.failedTickers ?? []
            existing.skippedContracts = skippedContractStrings
            existing.failedContracts  = failedContractIDs
            existing.errorMessages    = input.errorMessages
            existing.sourceUsed       = input.eodResult?.source
            existing.completedAt      = completedAt
            try await existing.save(on: db)
        } else {
            try await JobRun(
                runDate:          runDateOnly,
                status:           input.status.rawValue,
                equitiesFetched:  input.portfolioResult?.equityInstrumentIDs.count,
                optionsFetched:   input.portfolioResult?.optionInstrumentIDs.count,
                contractsPriced:  input.pricingResult?.contractsPriced,
                theoreticalRows:  input.pricingResult?.rowsUpserted,
                newContracts:     input.portfolioResult?.newContractsRegistered,
                droppedPositions: droppedPositionsStrings,
                failedTickers:    input.eodResult?.failedTickers ?? [],
                skippedContracts: skippedContractStrings,
                failedContracts:  failedContractIDs,
                errorMessages:    input.errorMessages,
                sourceUsed:       input.eodResult?.source,
                startedAt:        input.startedAt,
                completedAt:      completedAt
            ).create(on: db)
        }

        let duration = completedAt.timeIntervalSince(input.startedAt)
        logger.info("[RunLogActivity] wrote run log — runDate=\(input.runDate) status=\(input.status.rawValue) duration=\(String(format: "%.2f", duration))s")
    }
}

