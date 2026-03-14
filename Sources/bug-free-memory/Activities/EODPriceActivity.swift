//
//  EODPriceActivity.swift
//  bug-free-memory
//
//  Temporal activity that fetches EOD prices for all active equities and
//  indexes from Tiingo and upserts them into eod_prices.
//

import Fluent
import Foundation
import Logging
import Temporal
import TiingoKit

@ActivityContainer
struct EODPriceActivities {

    private let db: any Database
    private let tiingoClient: TiingoClient
    private let logger: Logger

    init(db: any Database, tiingoClient: TiingoClient, logger: Logger) {
        self.db = db
        self.tiingoClient = tiingoClient
        self.logger = logger
    }

    @Activity
    func fetchAndUpsertEODPrices(runDate: Date) async throws -> EODPriceResult {
        // 1. Resolve all active equity instrument IDs (indexes excluded — Tiingo doesn't cover them)
        let equityIDs = try await Equity.query(on: db).all().map { $0.id! }

        let instruments = try await Instrument.query(on: db)
            .filter(\.$isActive == true)
            .filter(\.$id ~~ equityIDs)
            .all()

        logger.info("[EODPriceActivity] starting — equities=\(equityIDs.count) activeInstruments=\(instruments.count) runDate=\(runDate)")

        var rowsUpserted = 0
        var failedTickers: [String] = []

        // 2. Fetch and upsert for each instrument
        for instrument in instruments {
            guard let instrumentID = instrument.id else { continue }
            let ticker = instrument.ticker

            logger.debug("[EODPriceActivity] fetching \(ticker)")
            let query = Tiingo.EODQuery(startDate: runDate, endDate: runDate)
            let prices: [Tiingo.EODPrice]
            do {
                prices = try await tiingoClient.eod(ticker: ticker, query: query)
            } catch TiingoError.httpError(let code, _) where code == 401 {
                logger.error("[EODPriceActivity] Tiingo auth failure (401) — aborting")
                throw TiingoError.httpError(statusCode: code, body: "auth failure")
            } catch {
                logger.warning("[EODPriceActivity] fetch failed for \(ticker): \(error)")
                failedTickers.append(ticker)
                continue
            }

            logger.debug("[EODPriceActivity] \(ticker) — \(prices.count) price(s) returned")

            guard let price = prices.last else {
                logger.warning("[EODPriceActivity] no price data for \(ticker) on \(runDate)")
                failedTickers.append(ticker)
                continue
            }

            let priceDate = Calendar.utc.startOfDay(for: price.date)
            logger.debug("[EODPriceActivity] upserting \(ticker) priceDate=\(priceDate) close=\(price.close)")

            do {
                if let existing = try await EODPrice.query(on: db)
                    .filter(\.$instrument.$id == instrumentID)
                    .filter(\.$priceDate == priceDate)
                    .first() {
                    existing.open     = price.open
                    existing.high     = price.high
                    existing.low      = price.low
                    existing.close    = price.close
                    existing.adjClose = price.adjClose
                    existing.volume   = price.volume
                    existing.source   = "tiingo"
                    try await existing.save(on: db)
                } else {
                    try await EODPrice(
                        instrumentID: instrumentID, priceDate: priceDate,
                        open: price.open, high: price.high, low: price.low,
                        close: price.close, adjClose: price.adjClose,
                        volume: price.volume, source: "tiingo"
                    ).create(on: db)
                }
            } catch {
                logger.error("[EODPriceActivity] upsert failed for \(ticker) (\(instrumentID)) priceDate=\(priceDate): \(error)")
                failedTickers.append(ticker)
                continue
            }

            rowsUpserted += 1
        }

        logger.info("[EODPriceActivity] complete — upserted=\(rowsUpserted) failed=\(failedTickers.count) failedTickers=\(failedTickers)")

        return EODPriceResult(
            rowsUpserted: rowsUpserted,
            instrumentsFetched: instruments.count,
            failedTickers: failedTickers,
            source: "tiingo"
        )
    }
}

