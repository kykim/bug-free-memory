//
//  PriceOptionContractWorkflow.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Foundation
import Temporal

public struct PriceOptionContractInput: Codable, Sendable {
    public let contractID: UUID

    public init(contractID: UUID) {
        self.contractID = contractID
    }
}

public struct PriceOptionContractResult: Codable, Sendable {
    public let contractID: UUID
    public let recordsUpserted: Int
}

@Workflow
public final class PriceOptionContractWorkflow {

    public func run(input: PriceOptionContractInput) async throws -> PriceOptionContractResult {
        let fastOptions = ActivityOptions(
            startToCloseTimeout: .seconds(30),
            retryPolicy: RetryPolicy(maximumAttempts: 3)
        )
        let mcOptions = ActivityOptions(
            startToCloseTimeout: .seconds(900),
            retryPolicy: RetryPolicy(maximumAttempts: 2)
        )

        let bs  = try await Workflow.executeActivity(
            PriceOptionContractActivities.Activities.PriceBlackScholes.self,
            options: fastOptions,
            input: input
        )
        let bin = try await Workflow.executeActivity(
            PriceOptionContractActivities.Activities.PriceBinomial.self,
            options: fastOptions,
            input: input
        )
        let mc  = try await Workflow.executeActivity(
            PriceOptionContractActivities.Activities.PriceMonteCarlo.self,
            options: mcOptions,
            input: input
        )

        return PriceOptionContractResult(contractID: input.contractID, recordsUpserted: bs + bin + mc)
    }
}
