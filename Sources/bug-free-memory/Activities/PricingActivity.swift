//
//  PricingActivity.swift
//  bug-free-memory
//
//  Temporal activity that prices all non-expired option contracts using
//  Black-Scholes, Binomial CRR, and Monte Carlo LSM, then upserts results
//  into theoretical_option_eod_prices.
//

import Fluent
import Foundation
import Logging
import Temporal

// MARK: - Errors

enum PricingError: Error {
    case noFREDRatesAvailable(runDate: Date)
}

// MARK: - Activity

@ActivityContainer
struct PricingActivities {

    private let db: any Database
    private let logger: Logger

    init(db: any Database, logger: Logger) {
        self.db = db
        self.logger = logger
    }

    @Activity
    func priceAllContracts(runDate: Date) async throws -> PricingResult {
        // 1. Load yield curve — abort early if empty
        let yieldCurve = try await YieldCurve.load(db: db, runDate: runDate)
        logger.info("[PricingActivity] yieldCurve points=\(yieldCurve.points.count)")
        guard !yieldCurve.points.isEmpty else {
            logger.error("[PricingActivity] noFREDRatesAvailable runDate=\(runDate)")
            throw PricingError.noFREDRatesAvailable(runDate: runDate)
        }

        // 2. Query non-expired contracts with their underlying
        let startOfDay = Calendar.utc.startOfDay(for: runDate)
        let endOfDay   = Calendar.utc.date(byAdding: .day, value: 1, to: startOfDay)!
        logger.info("[PricingActivity] starting runDate=\(runDate) startOfDay=\(startOfDay) endOfDay=\(endOfDay)")
        let contracts = try await OptionContract.query(on: db)
            .filter(\.$expirationDate >= startOfDay)
            .with(\.$underlying)
            .all()
        logger.info("[PricingActivity] contracts to price: \(contracts.count)")

        var contractsPriced = 0
        var totalRows = 0
        var failedContracts: [FailedContract] = []

        // 3. Process each contract concurrently
        let results = try await withThrowingTaskGroup(
            of: (UUID, Result<Int, FailedContract>).self
        ) { group in
            for contract in contracts {
                guard let id = contract.id else { continue }
                group.addTask {
                    let outcome = await self.priceContract(
                        contract: contract,
                        yieldCurve: yieldCurve,
                        runDate: runDate,
                        startOfDay: startOfDay,
                        endOfDay: endOfDay
                    )
                    return (id, outcome)
                }
            }
            var collected: [(UUID, Result<Int, FailedContract>)] = []
            for try await item in group {
                collected.append(item)
            }
            return collected
        }

        for (_, outcome) in results {
            switch outcome {
            case .success(let rows):
                contractsPriced += 1
                totalRows += rows
            case .failure(let fc):
                failedContracts.append(fc)
            }
        }

        logger.info("[PricingActivity] complete — priced=\(contractsPriced) rows=\(totalRows) failed=\(failedContracts.count)")

        return PricingResult(
            contractsPriced: contractsPriced,
            rowsUpserted: totalRows,
            failedContracts: failedContracts
        )
    }

    // MARK: - Private: price one contract

    private func priceContract(
        contract: OptionContract,
        yieldCurve: YieldCurve,
        runDate: Date,
        startOfDay: Date,
        endOfDay: Date
    ) async -> Result<Int, FailedContract> {
        guard let instrumentID = contract.id else {
            return .failure(FailedContract(instrumentID: UUID(), reason: "missing_instrument_id"))
        }

        // a. Fetch today's OptionEODPrice
        let optionEODOptional = try? await OptionEODPrice.query(on: db)
            .filter(\.$instrument.$id == instrumentID)
            .filter(\.$priceDate >= startOfDay)
            .filter(\.$priceDate < endOfDay)
            .first()
        guard let optionEOD = optionEODOptional ?? nil else {
            // Log the most recent EOD price date to diagnose the mismatch
            let mostRecent = try? await OptionEODPrice.query(on: db)
                .filter(\.$instrument.$id == instrumentID)
                .sort(\.$priceDate, .descending)
                .first()
            logger.warning("[PricingActivity] no_eod_price_today instrumentID=\(instrumentID) startOfDay=\(startOfDay) endOfDay=\(endOfDay) mostRecentPriceDate=\(mostRecent?.priceDate.description ?? "none")")
            return .failure(FailedContract(instrumentID: instrumentID, reason: "no_eod_price_today"))
        }

        // b. Fetch last 31 days of underlying EOD history (most recent first)
        let history = (try? await EODPrice.query(on: db)
            .filter(\.$instrument.$id == contract.$underlying.id)
            .sort(\.$priceDate, .descending)
            .limit(31)
            .all()) ?? []

        guard history.count >= 2 else {
            logger.warning("[PricingActivity] insufficient_history instrumentID=\(instrumentID) osiSymbol=\(contract.osiSymbol ?? "nil") historyCount=\(history.count)")
            return .failure(FailedContract(instrumentID: instrumentID, reason: "insufficient_history"))
        }

        // c. Interpolate risk-free rate
        let tte = contract.timeToExpiry(from: runDate)
        let r = yieldCurve.interpolate(timeToExpiry: tte)

        let latest = history.first!
        logger.debug("[PricingActivity] pricing instrumentID=\(instrumentID) osiSymbol=\(contract.osiSymbol ?? "nil") underlyingID=\(contract.$underlying.id) T=\(tte) r=\(r) historyCount=\(history.count) latestDate=\(latest.priceDate) latestClose=\(latest.close)")
        var rowsUpserted = 0

        // d. Price with all three models
        if let bsResult = contract.blackScholesPrice(
            currentPrice: latest, priceHistory: history, riskFreeRate: r
        ) {
            let record = TheoreticalOptionEODPrice.from(
                result: bsResult, instrumentID: instrumentID,
                priceDate: startOfDay, riskFreeRate: r,
                pricingModel: .blackScholes, source: "calculated"
            )
            record.impliedVolatility = optionEOD.impliedVolatility
            do { try await upsert(record: record); rowsUpserted += 1 } catch {
                logger.error("[PricingActivity] upsert blackScholes failed instrumentID=\(instrumentID) error=\(String(reflecting: error))")
            }
        } else {
            logger.warning("[PricingActivity] blackScholes returned nil instrumentID=\(instrumentID) osiSymbol=\(contract.osiSymbol ?? "nil") T=\(tte)")
        }

        if let binResult = contract.binomialPrice(
            currentPrice: latest, priceHistory: history, riskFreeRate: r
        ) {
            let record = TheoreticalOptionEODPrice.from(
                result: binResult, instrumentID: instrumentID,
                priceDate: startOfDay, riskFreeRate: r,
                pricingModel: .binomial, source: "calculated"
            )
            record.impliedVolatility = optionEOD.impliedVolatility
            do { try await upsert(record: record); rowsUpserted += 1 } catch {
                logger.error("[PricingActivity] upsert binomial failed instrumentID=\(instrumentID) error=\(String(reflecting: error))")
            }
        } else {
            logger.warning("[PricingActivity] binomial returned nil instrumentID=\(instrumentID) osiSymbol=\(contract.osiSymbol ?? "nil") T=\(tte)")
        }

        if let mcResult = contract.monteCarloPrice(
            currentPrice: latest, priceHistory: history, riskFreeRate: r,
            volatilityMethod: .historical(lookback: 30), simulations: 100_000, stepsPerPath: 252, computeGreeks: false
        ) {
            let record = TheoreticalOptionEODPrice.from(
                result: mcResult, instrumentID: instrumentID,
                priceDate: startOfDay, riskFreeRate: r, source: "calculated"
            )
            record.impliedVolatility = optionEOD.impliedVolatility
            do { try await upsert(record: record); rowsUpserted += 1 } catch {
                logger.error("[PricingActivity] upsert monteCarlo failed instrumentID=\(instrumentID) error=\(String(reflecting: error))")
            }
        } else {
            logger.warning("[PricingActivity] monteCarlo returned nil instrumentID=\(instrumentID) osiSymbol=\(contract.osiSymbol ?? "nil") T=\(tte)")
        }

        if rowsUpserted == 0 {
            logger.warning("[PricingActivity] all_pricers_returned_nil instrumentID=\(instrumentID) osiSymbol=\(contract.osiSymbol ?? "nil")")
            return .failure(FailedContract(instrumentID: instrumentID, reason: "all_pricers_returned_nil"))
        }

        logger.info("[PricingActivity] priced osiSymbol=\(contract.osiSymbol ?? "nil") rows=\(rowsUpserted)")
        return .success(rowsUpserted)
    }

    // MARK: - Private: upsert one theoretical price

    private func upsert(record: TheoreticalOptionEODPrice) async throws {
        let instrumentID = record.$instrument.id
        if let existing = try await TheoreticalOptionEODPrice.query(on: db)
            .filter(\.$instrument.$id == instrumentID)
            .filter(\.$priceDate == record.priceDate)
            .filter(\.$model == record.model)
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

