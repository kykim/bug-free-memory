//
//  PricingActivity.swift
//  bug-free-memory
//
//  Temporal activity that prices all non-expired option contracts using
//  Black-Scholes, Binomial CRR, and Monte Carlo LSM, then upserts results
//  into theoretical_option_eod_prices.
//

import Fluent
import FluentSQL
import Foundation
import Logging
import Temporal

// MARK: - Errors

enum PricingError: Error {
    case noFREDRatesAvailable(runDate: Date)
}

// MARK: - Activity

@ActivityContainer
public struct PricingActivities {

    private let db: any Database
    private let logger: Logger

    public init(db: any Database, logger: Logger) {
        self.db = db
        self.logger = logger
    }

    @Activity(
        retryPolicy: RetryPolicy(
            initialInterval: .seconds(10),
            backoffCoefficient: 1.5,
            maximumAttempts: 2
        ),
        scheduleToCloseTimeout: .seconds(1800)
    )
    public func priceAllContracts(runDate: Date) async throws -> PricingResult {
        // 1. Load yield curve — abort early if empty
        let yieldCurve = try await YieldCurve.load(db: db, runDate: runDate)
        guard !yieldCurve.points.isEmpty else {
            throw PricingError.noFREDRatesAvailable(runDate: runDate)
        }

        // 2. Query non-expired contracts with their underlying
        let startOfDay = Calendar.utcCal.startOfDay(for: runDate)
        let contracts = try await OptionContract.query(on: db)
            .filter(\.$expirationDate >= startOfDay)
            .with(\.$underlying)
            .all()

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
                        startOfDay: startOfDay
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
        startOfDay: Date
    ) async -> Result<Int, FailedContract> {
        guard let instrumentID = contract.id else {
            return .failure(FailedContract(instrumentID: UUID(), reason: "missing_instrument_id"))
        }

        // a. Fetch today's OptionEODPrice
        guard let optionEOD = try? await OptionEODPrice.query(on: db)
            .filter(\.$instrument.$id == instrumentID)
            .filter(\.$priceDate == startOfDay)
            .first(),
            optionEOD != nil else {
            return .failure(FailedContract(instrumentID: instrumentID, reason: "no_eod_price_today"))
        }

        // b. Fetch last 31 days of underlying EOD history
        let history = (try? await EODPrice.query(on: db)
            .filter(\.$instrument.$id == contract.$underlying.id)
            .sort(\.$priceDate, .ascending)
            .limit(31)
            .all()) ?? []

        guard history.count >= 2 else {
            return .failure(FailedContract(instrumentID: instrumentID, reason: "insufficient_history"))
        }

        // c. Interpolate risk-free rate
        let tte = contract.timeToExpiry(from: runDate)
        let r = yieldCurve.interpolate(timeToExpiry: tte)

        let latest = history.last!
        let sqlDB = db as! any SQLDatabase
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
            record.impliedVolatility = optionEOD!.impliedVolatility
            if (try? await upsert(record: record, on: sqlDB)) != nil { rowsUpserted += 1 }
        }

        if let binResult = contract.binomialPrice(
            currentPrice: latest, priceHistory: history, riskFreeRate: r
        ) {
            let record = TheoreticalOptionEODPrice.from(
                result: binResult, instrumentID: instrumentID,
                priceDate: startOfDay, riskFreeRate: r,
                pricingModel: .binomial, source: "calculated"
            )
            record.impliedVolatility = optionEOD!.impliedVolatility
            if (try? await upsert(record: record, on: sqlDB)) != nil { rowsUpserted += 1 }
        }

        if let mcResult = contract.monteCarloPrice(
            currentPrice: latest, priceHistory: history, riskFreeRate: r,
            lookback: 30, simulations: 100_000, stepsPerPath: 252, computeGreeks: false
        ) {
            let record = TheoreticalOptionEODPrice.from(
                result: mcResult, instrumentID: instrumentID,
                priceDate: startOfDay, riskFreeRate: r, source: "calculated"
            )
            record.impliedVolatility = optionEOD!.impliedVolatility
            if (try? await upsert(record: record, on: sqlDB)) != nil { rowsUpserted += 1 }
        }

        if rowsUpserted == 0 {
            return .failure(FailedContract(instrumentID: instrumentID, reason: "all_pricers_returned_nil"))
        }

        return .success(rowsUpserted)
    }

    // MARK: - Private: upsert one theoretical price

    private func upsert(record: TheoreticalOptionEODPrice, on sqlDB: any SQLDatabase) async throws {
        guard let instrumentID = record.$instrument.id else { return }
        let newID = UUID()
        let modelStr = record.model.rawValue

        try await sqlDB.raw("""
            INSERT INTO theoretical_option_eod_prices
                (id, instrument_id, price_date, price, settlement_price,
                 implied_volatility, historical_volatility, risk_free_rate,
                 underlying_price, delta, gamma, theta, vega, rho,
                 model, model_detail, source)
            VALUES
                (\(bind: newID), \(bind: instrumentID), \(bind: record.priceDate),
                 \(bind: record.price), \(bind: record.settlementPrice),
                 \(bind: record.impliedVolatility), \(bind: record.historicalVolatility),
                 \(bind: record.riskFreeRate), \(bind: record.underlyingPrice),
                 \(bind: record.delta), \(bind: record.gamma), \(bind: record.theta),
                 \(bind: record.vega), \(bind: record.rho),
                 \(bind: modelStr), \(bind: record.modelDetail), \(bind: record.source))
            ON CONFLICT (instrument_id, price_date, model) DO UPDATE SET
                price                = EXCLUDED.price,
                settlement_price     = EXCLUDED.settlement_price,
                implied_volatility   = EXCLUDED.implied_volatility,
                historical_volatility = EXCLUDED.historical_volatility,
                risk_free_rate       = EXCLUDED.risk_free_rate,
                underlying_price     = EXCLUDED.underlying_price,
                delta                = EXCLUDED.delta,
                gamma                = EXCLUDED.gamma,
                theta                = EXCLUDED.theta,
                vega                 = EXCLUDED.vega,
                rho                  = EXCLUDED.rho,
                model_detail         = EXCLUDED.model_detail,
                source               = EXCLUDED.source
            """).run()
    }
}

private extension Calendar {
    static let utcCal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
