//
//  SchwabClient+PriceHistory.swift
//  bug-free-memory
//
//  Extends SchwabClient with daily price history fetching via the
//  marketdata/v1/pricehistory endpoint.
//

import Foundation

// MARK: - Types

struct SchwabPriceHistory: Decodable {
    let symbol: String
    let empty: Bool
    let candles: [SchwabCandle]
}

struct SchwabCandle: Decodable {
    let open: Double
    let high: Double
    let low: Double
    let close: Double
    let volume: Int
    /// Milliseconds since Unix epoch.
    let datetime: Int64

    var date: Date { Date(timeIntervalSince1970: Double(datetime) / 1000.0) }
}

// MARK: - Extension

extension SchwabClient {

    /// Fetches 1 year of daily price history for the given ticker.
    func fetchPriceHistory(ticker: String) async throws -> SchwabPriceHistory {
        guard let encodedTicker = ticker.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.marketDataBaseURL)/pricehistory?symbol=\(encodedTicker)&periodType=year&period=1&frequencyType=daily&frequency=1&needPreviousClose=true") else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        return try await execute(authorizedRequest(url: url), as: SchwabPriceHistory.self)
    }
}
