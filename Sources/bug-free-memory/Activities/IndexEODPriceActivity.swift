//
//  IndexEODPriceActivity.swift
//  bug-free-memory
//
//  Temporal activity that fetches EOD prices for all active indexes
//  from the Schwab marketdata API and upserts them into eod_prices.
//

import Fluent
import Foundation
import Logging
import Temporal

@ActivityContainer
struct IndexEODPriceActivities {

    private let db: any Database
    private let schwabClient: SchwabClient
    private let logger: Logger

    init(db: any Database, schwabClient: SchwabClient, logger: Logger) {
        self.db = db
        self.schwabClient = schwabClient
        self.logger = logger
    }

    @Activity
    func fetchAndUpsertEODIndexPrices(runDate: Date) async throws -> EODPriceResult {
        // 1. Refresh token
        try await schwabClient.refreshTokenIfNeeded(db: db)

        // 2. Resolve all active index instruments
        let indexIDs = try await Index.query(on: db).all().map { $0.id! }
        let instruments = try await Instrument.query(on: db)
            .filter(\.$isActive == true)
            .filter(\.$id ~~ indexIDs)
            .all()

        logger.info("[IndexEODPriceActivity] starting — indexes=\(instruments.count) runDate=\(runDate)")

        let priceDate = Calendar.utc.startOfDay(for: runDate)
        var rowsUpserted = 0
        var failedTickers: [String] = []

        // 3. Fetch and upsert per index
        for instrument in instruments {
            guard let instrumentID = instrument.id else { continue }
            let ticker = instrument.ticker

            logger.debug("[IndexEODPriceActivity] fetching \(ticker)")
            let quote: SchwabIndexQuote?
            do {
                quote = try await schwabClient.fetchIndexQuote(ticker: ticker)
            } catch SchwabError.authFailure {
                logger.error("[IndexEODPriceActivity] Schwab auth failure (401) — aborting")
                throw SchwabError.authFailure
            } catch {
                logger.warning("[IndexEODPriceActivity] fetch failed for \(ticker): \(error)")
                failedTickers.append(ticker)
                continue
            }

            guard let q = quote, let close = q.closePrice else {
                logger.warning("[IndexEODPriceActivity] no quote for \(ticker) on \(runDate)")
                failedTickers.append(ticker)
                continue
            }

            logger.debug("[IndexEODPriceActivity] upserting \(ticker) priceDate=\(priceDate) close=\(close)")

            do {
                if let existing = try await EODPrice.query(on: db)
                    .filter(\.$instrument.$id == instrumentID)
                    .filter(\.$priceDate == priceDate)
                    .first() {
                    existing.open   = q.openPrice
                    existing.high   = q.highPrice
                    existing.low    = q.lowPrice
                    existing.close  = close
                    existing.volume = q.totalVolume
                    existing.source = "schwab"
                    try await existing.save(on: db)
                } else {
                    try await EODPrice(
                        instrumentID: instrumentID, priceDate: priceDate,
                        open: q.openPrice, high: q.highPrice, low: q.lowPrice,
                        close: close, volume: q.totalVolume, source: "schwab"
                    ).create(on: db)
                }
            } catch {
                logger.error("[IndexEODPriceActivity] upsert failed for \(ticker) (\(instrumentID)) priceDate=\(priceDate): \(error)")
                failedTickers.append(ticker)
                continue
            }

            rowsUpserted += 1
        }

        logger.info("[IndexEODPriceActivity] complete — upserted=\(rowsUpserted) failed=\(failedTickers.count) failedTickers=\(failedTickers)")

        return EODPriceResult(
            rowsUpserted: rowsUpserted,
            instrumentsFetched: instruments.count,
            failedTickers: failedTickers,
            source: "schwab"
        )
    }
}

