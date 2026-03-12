import Foundation
import Temporal
import Vapor

/// Abstracts Temporal workflow interaction for option contract pricing.
struct OptionPricingService {
    let temporal: TemporalClient
    let logger: Logger

    /// Triggers a pricing run for all three models (Black-Scholes, Binomial, Monte Carlo price only).
    func triggerPricing(for contractID: UUID) async throws {
        let workflowID = "price-option-\(contractID)-\(UUID())"
        _ = try await temporal.startWorkflow(
            type: PriceOptionContractWorkflow.self,
            options: .init(id: workflowID, taskQueue: "option-pricing"),
            input: PriceOptionContractInput(contractID: contractID)
        )
        logger.info("[option-pricing] started workflow \(workflowID) for contract \(contractID)")
    }

    /// Triggers the deferred Monte Carlo Greeks computation for an existing price record.
    func triggerGreeksComputation(for contractID: UUID) async throws {
        let workflowID = "mc-greeks-\(contractID)-\(UUID())"
        _ = try await temporal.startWorkflow(
            type: ComputeMonteCarloGreeksWorkflow.self,
            options: .init(id: workflowID, taskQueue: "option-pricing"),
            input: PriceOptionContractInput(contractID: contractID)
        )
        logger.info("[option-pricing] started MC Greeks workflow \(workflowID) for contract \(contractID)")
    }
}

extension Application {
    var optionPricingService: OptionPricingService {
        OptionPricingService(temporal: temporal, logger: logger)
    }
}

extension Request {
    var optionPricingService: OptionPricingService {
        application.optionPricingService
    }
}
