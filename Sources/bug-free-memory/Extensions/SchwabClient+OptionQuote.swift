//
//  SchwabClient+OptionQuote.swift
//  bug-free-memory
//
//  Extends SchwabClient with single-contract option EOD quote fetching.
//

import Foundation

// MARK: - Types

struct SchwabOptionQuote: Codable {
    let bid: Double?
    let ask: Double?
    let last: Double?
    let volume: Int?
    let openInterest: Int?
    let impliedVolatility: Double?
    let underlyingPrice: Double?
    let delta: Double?
    let gamma: Double?
    let theta: Double?
    let vega: Double?
    let rho: Double?

    enum CodingKeys: String, CodingKey {
        case bid, ask, last, volume
        case openInterest
        case impliedVolatility = "volatility"
        case underlyingPrice
        case delta, gamma, theta, vega, rho
    }
}

// MARK: - Extension

extension SchwabClient {

    /// Fetches an option EOD quote for the given OSI symbol.
    /// Returns nil if the symbol is absent from the response (e.g. expired contract).
    func fetchOptionEODPrice(osiSymbol: String) async throws -> SchwabOptionQuote? {
        guard let encoded = osiSymbol.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.marketDataBaseURL)/quotes?symbols=\(encoded)") else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        let request = authorizedRequest(url: url)
        let decoded = try await execute(request, as: [String: SchwabOptionQuote].self)
        return decoded[osiSymbol]
    }
}
