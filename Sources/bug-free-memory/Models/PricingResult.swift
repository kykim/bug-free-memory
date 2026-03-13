//
//  PricingResult.swift
//  bug-free-memory
//

import Foundation

struct FailedContract: Codable, Sendable, Error {
    let instrumentID: UUID
    let reason: String
}

struct PricingResult: Codable, Sendable {
    let contractsPriced: Int
    let rowsUpserted: Int
    let failedContracts: [FailedContract]
}
