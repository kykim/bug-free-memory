//
//  OptionEODPriceActivity.swift
//  bug-free-memory
//
//  Temporal activity that fetches EOD prices for all non-expired option
//  contracts from Schwab and upserts them into option_eod_prices.
//
//  IMPORTANT: The `mid` column is GENERATED ALWAYS AS ((bid + ask) / 2) STORED.
//  It must NEVER appear in INSERT or DO UPDATE clauses.
//

import Fluent
import FluentSQL
import Foundation
import Logging
import Temporal

@ActivityContainer
struct OptionEODPriceActivities {

    private let db: any Database
    private let schwabClient: SchwabClient
    private let logger: Logger

    init(db: any Database, schwabClient: SchwabClient, logger: Logger) {
        self.db = db
        self.schwabClient = schwabClient
        self.logger = logger
    }

    @Activity
    func fetchAndUpsertOptionEODPrices(runDate: Date) async throws -> OptionEODResult {
        // 1. Refresh token
        try await schwabClient.refreshTokenIfNeeded(db: db)

        // 2. Query non-expired contracts
        let startOfDay = Calendar.utcCal.startOfDay(for: runDate)
        let contracts = try await OptionContract.query(on: db)
            .filter(\.$expirationDate >= startOfDay)
            .all()

        // 3. Load yield curve once
        let yieldCurve = try await YieldCurve.load(db: db, runDate: runDate)

        let sqlDB = db as! any SQLDatabase
        var rowsUpserted = 0
        var skippedContracts: [SkippedContract] = []

        // 4. Fetch and upsert per contract
        for contract in contracts {
            guard let instrumentID = contract.id,
                  let osiSymbol = contract.osiSymbol else {
                skippedContracts.append(SkippedContract(
                    instrumentID: contract.id ?? UUID(),
                    osiSymbol: nil,
                    reason: "missing_osi_symbol"
                ))
                continue
            }

            let quote: SchwabOptionQuote?
            do {
                quote = try await schwabClient.fetchOptionQuote(osiSymbol: osiSymbol)
            } catch SchwabError.authFailure {
                throw SchwabError.authFailure
            } catch {
                logger.error("[OptionEODPriceActivity] fetch error for \(osiSymbol): \(error)")
                skippedContracts.append(SkippedContract(
                    instrumentID: instrumentID,
                    osiSymbol: osiSymbol,
                    reason: "fetch_error"
                ))
                continue
            }

            guard let q = quote else {
                logger.warning("[OptionEODPriceActivity] no quote for \(osiSymbol)")
                skippedContracts.append(SkippedContract(
                    instrumentID: instrumentID,
                    osiSymbol: osiSymbol,
                    reason: "no_quote"
                ))
                continue
            }

            // 5. Interpolate risk-free rate for this contract
            let tte = contract.timeToExpiry(from: runDate)
            let riskFreeRate = yieldCurve.interpolate(timeToExpiry: tte)

            let newID = UUID()

            // NOTE: mid is excluded — it is a GENERATED ALWAYS AS column
            try await sqlDB.raw("""
                INSERT INTO option_eod_prices
                    (id, instrument_id, price_date,
                     bid, ask, last, settlement_price, volume, open_interest,
                     implied_volatility, delta, gamma, theta, vega, rho,
                     underlying_price, risk_free_rate, source)
                VALUES
                    (\(bind: newID), \(bind: instrumentID), \(bind: startOfDay),
                     \(bind: q.bidPrice), \(bind: q.askPrice), \(bind: q.lastPrice),
                     \(bind: q.closePrice), \(bind: q.totalVolume), \(bind: q.openInterest),
                     \(bind: q.volatility.map { $0 / 100.0 }), \(bind: q.delta), \(bind: q.gamma),
                     \(bind: q.theta), \(bind: q.vega), \(bind: q.rho),
                     \(bind: q.underlyingPrice), \(bind: riskFreeRate), 'schwab')
                ON CONFLICT (instrument_id, price_date) DO UPDATE SET
                    bid               = EXCLUDED.bid,
                    ask               = EXCLUDED.ask,
                    last              = EXCLUDED.last,
                    volume            = EXCLUDED.volume,
                    open_interest     = EXCLUDED.open_interest,
                    implied_volatility = EXCLUDED.implied_volatility,
                    delta             = EXCLUDED.delta,
                    gamma             = EXCLUDED.gamma,
                    theta             = EXCLUDED.theta,
                    vega              = EXCLUDED.vega,
                    rho               = EXCLUDED.rho,
                    underlying_price  = EXCLUDED.underlying_price,
                    risk_free_rate    = EXCLUDED.risk_free_rate,
                    source            = 'schwab'
                """).run()

            rowsUpserted += 1
        }

        logger.info("[OptionEODPriceActivity] complete — upserted=\(rowsUpserted) skipped=\(skippedContracts.count)")

        return OptionEODResult(
            contractsProcessed: contracts.count,
            rowsUpserted: rowsUpserted,
            skippedContracts: skippedContracts
        )
    }
}

private extension Calendar {
    static let utcCal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
