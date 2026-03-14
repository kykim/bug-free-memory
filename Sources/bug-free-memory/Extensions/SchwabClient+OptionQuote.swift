//
//  SchwabClient+OptionQuote.swift
//  bug-free-memory
//
//  Extends SchwabClient with single-contract option quote fetching via
//  the marketdata/v1/quotes endpoint.
//

import Foundation

// MARK: - Types

struct SchwabOptionQuote: Decodable {
    let bidPrice: Double?
    let askPrice: Double?
    let lastPrice: Double?
    let closePrice: Double?
    let mark: Double?
    let totalVolume: Int?
    let openInterest: Int?
    /// Implied volatility as a percentage (e.g. 32.75 = 32.75%). Divide by 100 before storing.
    let volatility: Double?
    let delta: Double?
    let gamma: Double?
    let theta: Double?
    let vega: Double?
    let rho: Double?
    let underlyingPrice: Double?
}

// MARK: - Extension

extension SchwabClient {

    /// Fetches a real-time quote for the given OSI option symbol.
    /// Returns nil if the symbol is absent from the response (e.g. expired contract).
    func fetchOptionQuote(osiSymbol: String) async throws -> SchwabOptionQuote? {
        guard let encoded = osiSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.marketDataBaseURL)/quotes?symbols=\(encoded)&fields=quote,fundamental,reference&indicative=false") else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        struct Entry: Decodable { let quote: SchwabOptionQuote }
        let decoded = try await execute(authorizedRequest(url: url), as: [String: Entry].self)
        return decoded[osiSymbol]?.quote
    }
}
