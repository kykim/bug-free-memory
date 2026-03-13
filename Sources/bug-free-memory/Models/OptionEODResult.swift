//
//  OptionEODResult.swift
//  bug-free-memory
//

import Foundation

struct SkippedContract: Codable, Sendable {
    let instrumentID: UUID
    let osiSymbol: String?
    let reason: String
}

struct OptionEODResult: Codable, Sendable {
    let contractsProcessed: Int
    let rowsUpserted: Int
    let skippedContracts: [SkippedContract]
}
