//
//  FetchTiingoEODPriceActivity.swift
//  hello
//
//  Created by Kevin Y Kim on 3/10/26.
//

import Foundation
import Temporal
import TiingoKit

// MARK: - Shared input/output types

/// Input for the EOD price sync workflow.
public struct UpdateEODPricesInput: Codable, Sendable {
    public let equityID: UUID
    public let ticker: String
    /// Inclusive start date. Nil → Tiingo default (1 year ago).
    public let startDate: Date?
    /// Inclusive end date. Nil → Tiingo default (today).
    public let endDate: Date?

    public init(equityID: UUID, ticker: String, startDate: Date? = nil, endDate: Date? = nil) {
        self.equityID = equityID
        self.ticker = ticker
        self.startDate = startDate
        self.endDate = endDate
    }
}

/// Carries fetched prices from the fetch activity to the upsert activity.
public struct FetchedEODPrices: Codable, Sendable {
    public let equityID: UUID
    public let ticker: String
    public let prices: [Tiingo.EODPrice]
}

// MARK: - FetchTiingoPricesActivities

@ActivityContainer
public struct FetchTiingoPricesActivities {

    private let client: TiingoClient

    public init(tiingo: TiingoClient) {
        self.client = tiingo
    }

    /// Fetches EOD prices from Tiingo for the given ticker and optional date range.
    @Activity
    public func fetchEODPrices(input: UpdateEODPricesInput) async throws -> FetchedEODPrices {
        let query = Tiingo.EODQuery(
            startDate: input.startDate,
            endDate: input.endDate
        )
        let prices = try await client.eod(ticker: input.ticker, query: query)
        return FetchedEODPrices(
            equityID: input.equityID,
            ticker: input.ticker,
            prices: prices
        )
    }
}
