//
//  EODPriceResult.swift
//  bug-free-memory
//

import Foundation

struct EODPriceResult: Codable, Sendable {
    let rowsUpserted: Int
    let instrumentsFetched: Int
    let failedTickers: [String]
    let source: String
}
