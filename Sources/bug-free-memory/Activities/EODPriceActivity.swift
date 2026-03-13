//
//  EODPriceActivity.swift
//  bug-free-memory
//
//  Temporal activity that fetches EOD prices for all active equities and
//  indexes from Tiingo and upserts them into eod_prices.
//

import Fluent
import FluentSQL
import Foundation
import Logging
import Temporal
import TiingoKit

@ActivityContainer
public struct EODPriceActivities {

    private let db: any Database
    private let tiingoClient: TiingoClient
    private let logger: Logger

    public init(db: any Database, tiingoClient: TiingoClient, logger: Logger) {
        self.db = db
        self.tiingoClient = tiingoClient
        self.logger = logger
    }

    @Activity(
        retryPolicy: RetryPolicy(
            initialInterval: .seconds(30),
            backoffCoefficient: 2.0,
            maximumAttempts: 3
        ),
        scheduleToCloseTimeout: .seconds(300)
    )
    public func fetchAndUpsertEODPrices(runDate: Date) async throws -> EODPriceResult {
        // 1. Resolve all active equity and index instrument IDs
        let equityIDs = try await Equity.query(on: db).all().map { $0.id! }
        let indexIDs  = try await Index.query(on: db).all().map { $0.id! }
        let allIDs    = Array(Set(equityIDs + indexIDs))

        let instruments = try await Instrument.query(on: db)
            .filter(\.$isActive == true)
            .filter(\.$id ~~ allIDs)
            .all()

        let sqlDB = db as! any SQLDatabase

        var rowsUpserted = 0
        var failedTickers: [String] = []

        // 2. Fetch and upsert for each instrument
        for instrument in instruments {
            guard let instrumentID = instrument.id else { continue }
            let ticker = instrument.ticker

            let query = Tiingo.EODQuery(startDate: runDate, endDate: runDate)
            let prices: [Tiingo.EODPrice]
            do {
                prices = try await tiingoClient.eod(ticker: ticker, query: query)
            } catch TiingoError.httpError(let code, _) where code == 401 {
                throw TiingoError.httpError(statusCode: code, body: "auth failure")
            } catch {
                logger.warning("[EODPriceActivity] skipping \(ticker): \(error)")
                failedTickers.append(ticker)
                continue
            }

            guard let price = prices.last else {
                logger.warning("[EODPriceActivity] no data for \(ticker) on \(runDate)")
                failedTickers.append(ticker)
                continue
            }

            let priceDate = Calendar.utcCal.startOfDay(for: price.date)
            let newID = UUID()

            try await sqlDB.raw("""
                INSERT INTO eod_prices
                    (id, instrument_id, price_date, open, high, low, close, adj_close, volume, source)
                VALUES
                    (\(bind: newID), \(bind: instrumentID), \(bind: priceDate),
                     \(bind: price.open), \(bind: price.high), \(bind: price.low),
                     \(bind: price.close), \(bind: price.adjClose), \(bind: price.volume),
                     'tiingo')
                ON CONFLICT (instrument_id, price_date) DO UPDATE SET
                    open      = EXCLUDED.open,
                    high      = EXCLUDED.high,
                    low       = EXCLUDED.low,
                    close     = EXCLUDED.close,
                    adj_close = EXCLUDED.adj_close,
                    volume    = EXCLUDED.volume,
                    source    = 'tiingo'
                """).run()

            rowsUpserted += 1
        }

        logger.info("[EODPriceActivity] complete — upserted=\(rowsUpserted) failed=\(failedTickers.count)")

        return EODPriceResult(
            rowsUpserted: rowsUpserted,
            instrumentsFetched: instruments.count,
            failedTickers: failedTickers,
            source: "tiingo"
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
