//
//  SchwabClient+IndexQuote.swift
//  bug-free-memory
//
//  Extends SchwabClient with index EOD quote fetching via the
//  marketdata/v1/<ticker>/quotes endpoint.
//

import Foundation

// MARK: - Types

struct SchwabIndexQuote: Decodable {
    let openPrice: Double?
    let highPrice: Double?
    let lowPrice: Double?
    let closePrice: Double?
    let totalVolume: Int?
}

// MARK: - Extension

extension SchwabClient {

    /// Fetches a quote for the given index ticker.
    /// Returns nil if the ticker is absent from the response.
    func fetchIndexQuote(ticker: String) async throws -> SchwabIndexQuote? {
        guard let encoded = ticker.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "\(Self.marketDataBaseURL)/\(encoded)/quotes?fields=quote,reference,fundamental") else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        struct Entry: Decodable { let quote: SchwabIndexQuote }
        let decoded = try await execute(authorizedRequest(url: url), as: [String: Entry].self)
        return decoded[ticker]?.quote
    }
}
