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
        let startOfDay = Calendar.utc.startOfDay(for: runDate)
        let contracts = try await OptionContract.query(on: db)
            .filter(\.$expirationDate >= startOfDay)
            .all()

        // 3. Load yield curve once
        let yieldCurve = try await YieldCurve.load(db: db, runDate: runDate)

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

            let iv = q.volatility.map { $0 / 100.0 }
            if let existing = try await OptionEODPrice.query(on: db)
                .filter(\.$instrument.$id == instrumentID)
                .filter(\.$priceDate == startOfDay)
                .first() {
                existing.bid              = q.bidPrice
                existing.ask              = q.askPrice
                existing.last             = q.lastPrice
                existing.settlementPrice  = q.closePrice
                existing.volume           = q.totalVolume
                existing.openInterest     = q.openInterest
                existing.impliedVolatility = iv
                existing.delta            = q.delta
                existing.gamma            = q.gamma
                existing.theta            = q.theta
                existing.vega             = q.vega
                existing.rho              = q.rho
                existing.underlyingPrice  = q.underlyingPrice
                existing.riskFreeRate     = riskFreeRate
                existing.source           = "schwab"
                try await existing.save(on: db)
            } else {
                try await OptionEODPrice(
                    instrumentID: instrumentID, priceDate: startOfDay,
                    bid: q.bidPrice, ask: q.askPrice, last: q.lastPrice,
                    settlementPrice: q.closePrice, volume: q.totalVolume,
                    openInterest: q.openInterest, impliedVolatility: iv,
                    delta: q.delta, gamma: q.gamma, theta: q.theta,
                    vega: q.vega, rho: q.rho, underlyingPrice: q.underlyingPrice,
                    riskFreeRate: riskFreeRate, source: "schwab"
                ).create(on: db)
            }

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

