//
//  FilteredPositionSet.swift
//  bug-free-memory
//

import Foundation

struct DroppedPosition: Codable, Sendable {
    let ticker: String
    let reason: String
}

struct FilteredPositionSet: Codable, Sendable {
    let equityInstrumentIDs: [UUID]
    let optionInstrumentIDs: [UUID]
    let newContractsRegistered: Int
    let droppedPositions: [DroppedPosition]
    let runDate: Date
}
