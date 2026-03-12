//
//  ComputeMonteCarloGreeksWorkflow.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/12/26.
//
//  Deferred workflow that runs the full Monte Carlo simulation (with all Greek
//  bump-and-reprice passes) and updates the existing theoretical price record.
//  Intended to be triggered after `PriceOptionContractWorkflow` completes.
//

import Foundation
import Temporal

@Workflow
public final class ComputeMonteCarloGreeksWorkflow {

    public func run(input: PriceOptionContractInput) async throws -> PriceOptionContractResult {
        let options = ActivityOptions(
            startToCloseTimeout: .seconds(900),
            retryPolicy: RetryPolicy(maximumAttempts: 2)
        )
        let count = try await Workflow.executeActivity(
            PriceOptionContractActivities.Activities.ComputeMonteCarloGreeks.self,
            options: options,
            input: input
        )
        return PriceOptionContractResult(contractID: input.contractID, recordsUpserted: count)
    }
}
