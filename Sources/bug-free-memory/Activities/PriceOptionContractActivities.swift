//
//  PriceOptionContractActivities.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Foundation
import Fluent
import Temporal

enum PriceOptionContractError: Error {
    case contractNotFound
    case noEODHistory
}

@ActivityContainer
public struct PriceOptionContractActivities {

    private let db: any Database

    public init(db: any Database) {
        self.db = db
    }

    @Activity
    public func priceBlackScholes(input: PriceOptionContractInput) async throws -> Int {
        let (contract, latest, eodHistory, priceDate, riskFreeRate) = try await fetchPricingInputs(contractID: input.contractID)
        guard let result = contract.blackScholesPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, lookback: 30) else { return 0 }
        let record = TheoreticalOptionEODPrice.from(result: result, instrumentID: input.contractID, priceDate: priceDate, riskFreeRate: riskFreeRate, pricingModel: .blackScholes, source: "calculated")
        try await upsert(record, contractID: input.contractID, priceDate: priceDate, model: .blackScholes)
        return 1
    }

    @Activity
    public func priceBinomial(input: PriceOptionContractInput) async throws -> Int {
        let (contract, latest, eodHistory, priceDate, riskFreeRate) = try await fetchPricingInputs(contractID: input.contractID)
        guard let result = contract.binomialPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, lookback: 30) else { return 0 }
        let record = TheoreticalOptionEODPrice.from(result: result, instrumentID: input.contractID, priceDate: priceDate, riskFreeRate: riskFreeRate, pricingModel: .binomial, source: "calculated")
        try await upsert(record, contractID: input.contractID, priceDate: priceDate, model: .binomial)
        return 1
    }

    /// Runs the full Monte Carlo simulation and stores the price. Greeks are not computed
    /// here — use `computeMonteCarloGreeks` as a separate deferred step.
    @Activity
    public func priceMonteCarloPriceOnly(input: PriceOptionContractInput) async throws -> Int {
        let (contract, latest, eodHistory, priceDate, riskFreeRate) = try await fetchPricingInputs(contractID: input.contractID)
        guard let result = contract.monteCarloPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, lookback: 30, simulations: 100_000, stepsPerPath: 252, computeGreeks: false) else { return 0 }
        let record = TheoreticalOptionEODPrice.from(result: result, instrumentID: input.contractID, priceDate: priceDate, riskFreeRate: riskFreeRate, source: "calculated")
        try await upsert(record, contractID: input.contractID, priceDate: priceDate, model: .monteCarlo)
        return 1
    }

    /// Runs the Monte Carlo simulation with all Greeks (7–8 bump-and-reprice runs at n/4
    /// simulations each) and updates the Greeks on the existing price record in-place.
    /// Intended to be called from `ComputeMonteCarloGreeksWorkflow` as a deferred step.
    @Activity
    public func computeMonteCarloGreeks(input: PriceOptionContractInput) async throws -> Int {
        let (contract, latest, eodHistory, priceDate, riskFreeRate) = try await fetchPricingInputs(contractID: input.contractID)
        guard let result = contract.monteCarloPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, lookback: 30, simulations: 100_000, stepsPerPath: 252, computeGreeks: true) else { return 0 }
        guard let existing = try await TheoreticalOptionEODPrice.query(on: db)
            .filter(\.$instrument.$id == input.contractID)
            .filter(\.$priceDate == priceDate)
            .filter(\.$model == .monteCarlo)
            .first() else { return 0 }
        existing.delta = result.greeks?.delta
        existing.gamma = result.greeks?.gamma
        existing.theta = result.greeks?.theta
        existing.vega  = result.greeks?.vega
        existing.rho   = result.greeks?.rho
        try await existing.save(on: db)
        return 1
    }

    // MARK: - Helpers

    private func fetchPricingInputs(contractID: UUID) async throws -> (OptionContract, EODPrice, [EODPrice], Date, Double) {
        guard let contract = try await OptionContract.query(on: db)
            .filter(\.$id == contractID)
            .first() else {
            throw PriceOptionContractError.contractNotFound
        }
        let eodHistory = try await EODPrice.query(on: db)
            .filter(\.$instrument.$id == contract.$underlying.id)
            .sort(\.$priceDate, .descending)
            .limit(31)
            .all()
        guard let latest = eodHistory.first else {
            throw PriceOptionContractError.noEODHistory
        }
        let priceDate = Calendar.utc.startOfDay(for: latest.priceDate)
        let timeToExpiry = contract.timeToExpiry(from: latest.priceDate)
        let rfrResult = try await RiskFreeRateService(db: db).rate(for: latest.priceDate, timeToExpiry: timeToExpiry)
        return (contract, latest, eodHistory, priceDate, rfrResult.continuousRate)
    }

    private func upsert(_ record: TheoreticalOptionEODPrice, contractID: UUID, priceDate: Date, model: PricingModel) async throws {
        if let existing = try await TheoreticalOptionEODPrice.query(on: db)
            .filter(\.$instrument.$id == contractID)
            .filter(\.$priceDate == priceDate)
            .filter(\.$model == model)
            .first() {
            existing.price                = record.price
            existing.settlementPrice      = record.settlementPrice
            existing.impliedVolatility    = record.impliedVolatility
            existing.historicalVolatility = record.historicalVolatility
            existing.riskFreeRate         = record.riskFreeRate
            existing.underlyingPrice      = record.underlyingPrice
            existing.delta                = record.delta
            existing.gamma                = record.gamma
            existing.theta                = record.theta
            existing.vega                 = record.vega
            existing.rho                  = record.rho
            existing.modelDetail          = record.modelDetail
            existing.source               = record.source
            try await existing.save(on: db)
        } else {
            try await record.create(on: db)
        }
    }
}

private extension Calendar {
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
