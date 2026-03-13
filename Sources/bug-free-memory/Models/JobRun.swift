//
//  JobRun.swift
//  bug-free-memory
//

import Fluent
import Vapor

final class JobRun: Model, Content, @unchecked Sendable {
    static let schema = "job_runs"

    @ID
    var id: UUID?

    @Field(key: "run_date")
    var runDate: Date

    @Field(key: "status")
    var status: String

    @OptionalField(key: "equities_fetched")
    var equitiesFetched: Int?

    @OptionalField(key: "options_fetched")
    var optionsFetched: Int?

    @OptionalField(key: "contracts_priced")
    var contractsPriced: Int?

    @OptionalField(key: "theoretical_rows")
    var theoreticalRows: Int?

    @OptionalField(key: "new_contracts")
    var newContracts: Int?

    @OptionalField(key: "dropped_positions")
    var droppedPositions: [String]?

    @OptionalField(key: "failed_tickers")
    var failedTickers: [String]?

    @OptionalField(key: "skipped_contracts")
    var skippedContracts: [String]?

    @OptionalField(key: "failed_contracts")
    var failedContracts: [UUID]?

    @OptionalField(key: "error_messages")
    var errorMessages: [String]?

    @OptionalField(key: "source_used")
    var sourceUsed: String?

    @Field(key: "started_at")
    var startedAt: Date

    @OptionalField(key: "completed_at")
    var completedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        runDate: Date,
        status: String,
        equitiesFetched: Int? = nil,
        optionsFetched: Int? = nil,
        contractsPriced: Int? = nil,
        theoreticalRows: Int? = nil,
        newContracts: Int? = nil,
        droppedPositions: [String]? = nil,
        failedTickers: [String]? = nil,
        skippedContracts: [String]? = nil,
        failedContracts: [UUID]? = nil,
        errorMessages: [String]? = nil,
        sourceUsed: String? = nil,
        startedAt: Date,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.runDate = runDate
        self.status = status
        self.equitiesFetched = equitiesFetched
        self.optionsFetched = optionsFetched
        self.contractsPriced = contractsPriced
        self.theoreticalRows = theoreticalRows
        self.newContracts = newContracts
        self.droppedPositions = droppedPositions
        self.failedTickers = failedTickers
        self.skippedContracts = skippedContracts
        self.failedContracts = failedContracts
        self.errorMessages = errorMessages
        self.sourceUsed = sourceUsed
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}
