//
//  UpdateEODPricesWorkflow.swift
//  hello
//
//  Created by Kevin Y Kim on 3/10/26.
//

import Temporal

public struct UpdateEODPricesResult: Codable, Sendable {
    public let ticker: String
    public let recordsUpserted: Int
}

@Workflow
public final class UpdateEODPricesWorkflow {

    public func run(input: UpdateEODPricesInput) async throws -> UpdateEODPricesResult {

        let fetchOptions = ActivityOptions(
            startToCloseTimeout: .seconds(30),
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(2),
                backoffCoefficient: 2.0,
                maximumInterval: .seconds(30),
                maximumAttempts: 3
            )
        )

        let upsertOptions = ActivityOptions(
            startToCloseTimeout: .seconds(60),
            retryPolicy: RetryPolicy(maximumAttempts: 3)
        )

        // Step 1: fetch EOD prices from Tiingo
        let fetched = try await Workflow.executeActivity(
            FetchTiingoPricesActivities.Activities.FetchEODPrices.self,
            options: fetchOptions,
            input: input
        )

        // Step 2: upsert into DB
        let count = try await Workflow.executeActivity(
            UpsertEODPricesActivities.Activities.UpsertEODPrices.self,
            options: upsertOptions,
            input: fetched
        )

        return UpdateEODPricesResult(ticker: input.ticker, recordsUpserted: count)
    }
}
