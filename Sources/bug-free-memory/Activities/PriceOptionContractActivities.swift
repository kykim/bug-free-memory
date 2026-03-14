//
//  PriceOptionContractActivities.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Foundation
import Fluent
import Logging
import Temporal

enum PriceOptionContractError: Error {
    case contractNotFound
    case noEODHistory
}

@ActivityContainer
public struct PriceOptionContractActivities {

    private let db: any Database
    private let logger: Logger

    public init(db: any Database, logger: Logger) {
        self.db     = db
        self.logger = logger
    }

    @Activity
    public func priceBlackScholes(input: PriceOptionContractInput) async throws -> Int {
        logger.info("[PriceOptionContract] priceBlackScholes contractID=\(input.contractID)")
        let (contract, latest, eodHistory, priceDate, riskFreeRate, marketIV) = try await fetchPricingInputs(contractID: input.contractID)
        let record: TheoreticalOptionEODPrice
        if let result = contract.blackScholesPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, volatilityMethod: .historical(lookback: 30)) {
            logger.info("[PriceOptionContract] blackScholes price=\(result.price) contractID=\(input.contractID)")
            record = TheoreticalOptionEODPrice.from(result: result, instrumentID: input.contractID, priceDate: priceDate, riskFreeRate: riskFreeRate, pricingModel: .blackScholes, source: "calculated")
        } else {
            logger.warning("[PriceOptionContract] blackScholes returned nil contractID=\(input.contractID) T=\(contract.timeToExpiry()) historyCount=\(eodHistory.count) — upserting 0.00")
            record = TheoreticalOptionEODPrice(
                instrumentID: input.contractID,
                priceDate: priceDate,
                price: 0.0,
                historicalVolatility: 0.0,
                riskFreeRate: riskFreeRate,
                underlyingPrice: latest.adjClose ?? latest.close,
                model: .blackScholes,
                source: "calculated"
            )
        }
        record.impliedVolatility = marketIV ?? record.impliedVolatility
        try await upsert(record, contractID: input.contractID, priceDate: priceDate, model: .blackScholes)
        return 1
    }

    @Activity
    public func priceBinomial(input: PriceOptionContractInput) async throws -> Int {
        logger.info("[PriceOptionContract] priceBinomial contractID=\(input.contractID)")
        let (contract, latest, eodHistory, priceDate, riskFreeRate, marketIV) = try await fetchPricingInputs(contractID: input.contractID)
        let record: TheoreticalOptionEODPrice
        if let result = contract.binomialPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, volatilityMethod: .historical(lookback: 30)) {
            logger.info("[PriceOptionContract] binomial price=\(result.price) contractID=\(input.contractID)")
            record = TheoreticalOptionEODPrice.from(result: result, instrumentID: input.contractID, priceDate: priceDate, riskFreeRate: riskFreeRate, pricingModel: .binomial, source: "calculated")
        } else {
            logger.warning("[PriceOptionContract] binomial returned nil contractID=\(input.contractID) T=\(contract.timeToExpiry()) historyCount=\(eodHistory.count) — upserting 0.00")
            record = TheoreticalOptionEODPrice(
                instrumentID: input.contractID,
                priceDate: priceDate,
                price: 0.0,
                historicalVolatility: 0.0,
                riskFreeRate: riskFreeRate,
                underlyingPrice: latest.adjClose ?? latest.close,
                model: .binomial,
                source: "calculated"
            )
        }
        record.impliedVolatility = marketIV ?? record.impliedVolatility
        try await upsert(record, contractID: input.contractID, priceDate: priceDate, model: .binomial)
        return 1
    }

    /// Runs the full Monte Carlo simulation and stores the price. Greeks are not computed
    /// here — use `computeMonteCarloGreeks` as a separate deferred step.
    @Activity
    public func priceMonteCarloPriceOnly(input: PriceOptionContractInput) async throws -> Int {
        logger.info("[PriceOptionContract] priceMonteCarloPriceOnly contractID=\(input.contractID)")
        let (contract, latest, eodHistory, priceDate, riskFreeRate, marketIV) = try await fetchPricingInputs(contractID: input.contractID)
        let record: TheoreticalOptionEODPrice
        if let result = contract.monteCarloPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, volatilityMethod: .historical(lookback: 30), simulations: 100_000, stepsPerPath: 252, computeGreeks: false) {
            logger.info("[PriceOptionContract] monteCarlo price=\(result.price) contractID=\(input.contractID)")
            record = TheoreticalOptionEODPrice.from(result: result, instrumentID: input.contractID, priceDate: priceDate, riskFreeRate: riskFreeRate, source: "calculated")
        } else {
            logger.warning("[PriceOptionContract] monteCarlo returned nil contractID=\(input.contractID) T=\(contract.timeToExpiry()) historyCount=\(eodHistory.count) — upserting 0.00")
            record = TheoreticalOptionEODPrice(
                instrumentID: input.contractID,
                priceDate: priceDate,
                price: 0.0,
                historicalVolatility: 0.0,
                riskFreeRate: riskFreeRate,
                underlyingPrice: latest.adjClose ?? latest.close,
                model: .monteCarlo,
                source: "calculated"
            )
        }
        record.impliedVolatility = marketIV ?? record.impliedVolatility
        try await upsert(record, contractID: input.contractID, priceDate: priceDate, model: .monteCarlo)
        return 1
    }

    /// Runs the Monte Carlo simulation with all Greeks (7–8 bump-and-reprice runs at n/4
    /// simulations each) and updates the Greeks on the existing price record in-place.
    /// Intended to be called from `ComputeMonteCarloGreeksWorkflow` as a deferred step.
    @Activity
    public func computeMonteCarloGreeks(input: PriceOptionContractInput) async throws -> Int {
        logger.info("[PriceOptionContract] computeMonteCarloGreeks contractID=\(input.contractID)")
        let (contract, latest, eodHistory, priceDate, riskFreeRate, _) = try await fetchPricingInputs(contractID: input.contractID)
        guard let result = contract.monteCarloPrice(currentPrice: latest, priceHistory: eodHistory, riskFreeRate: riskFreeRate, volatilityMethod: .historical(lookback: 30), simulations: 100_000, stepsPerPath: 252, computeGreeks: true) else {
            logger.warning("[PriceOptionContract] computeMonteCarloGreeks returned nil contractID=\(input.contractID)")
            return 0
        }
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

    private func fetchPricingInputs(contractID: UUID) async throws -> (OptionContract, EODPrice, [EODPrice], Date, Double, Double?) {
        guard let contract = try await OptionContract.query(on: db)
            .filter(\.$id == contractID)
            .first() else {
            logger.error("[PriceOptionContract] contractNotFound contractID=\(contractID)")
            throw PriceOptionContractError.contractNotFound
        }
        logger.debug("[PriceOptionContract] contract found id=\(contractID) expiry=\(contract.expirationDate) strike=\(contract.strikePrice) T=\(contract.timeToExpiry())")
        let eodHistory = try await EODPrice.query(on: db)
            .filter(\.$instrument.$id == contract.$underlying.id)
            .sort(\.$priceDate, .descending)
            .limit(31)
            .all()
        guard let latest = eodHistory.first else {
            logger.error("[PriceOptionContract] noEODHistory contractID=\(contractID) underlying=\(contract.$underlying.id)")
            throw PriceOptionContractError.noEODHistory
        }
        logger.debug("[PriceOptionContract] eodHistory count=\(eodHistory.count) latestDate=\(latest.priceDate) latestClose=\(latest.close)")
        let priceDate = Calendar.utc.startOfDay(for: latest.priceDate)
        let nextDay = Calendar.utc.date(byAdding: .day, value: 1, to: priceDate)!

        // Fetch market IV from today's option EOD price (mirrors what the batch pricer does)
        let marketIV = try? await OptionEODPrice.query(on: db)
            .filter(\.$instrument.$id == contractID)
            .filter(\.$priceDate >= priceDate)
            .filter(\.$priceDate < nextDay)
            .first()
            .flatMap { $0.impliedVolatility }

        let timeToExpiry = contract.timeToExpiry(from: latest.priceDate)
        do {
            let rfrResult = try await RiskFreeRateService(db: db).rate(for: latest.priceDate, timeToExpiry: timeToExpiry)
            logger.debug("[PriceOptionContract] riskFreeRate=\(rfrResult.continuousRate) observationDate=\(rfrResult.observationDate)")
            return (contract, latest, eodHistory, priceDate, rfrResult.continuousRate, marketIV)
        } catch {
            logger.error("[PriceOptionContract] RiskFreeRateService failed: \(error) — falling back to 0.05")
            return (contract, latest, eodHistory, priceDate, 0.05, marketIV)
        }
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
