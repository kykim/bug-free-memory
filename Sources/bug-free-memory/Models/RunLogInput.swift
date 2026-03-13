//
//  RunLogInput.swift
//  bug-free-memory
//

import Foundation

enum RunStatus: String, Codable, Sendable {
    case success
    case partial
    case failed
    case skipped

    static func determine(
        portfolioResult: FilteredPositionSet?,
        eodResult: EODPriceResult?,
        optionEODResult: OptionEODResult?,
        pricingResult: PricingResult?,
        errorMessages: [String],
        forceSkipped: Bool = false
    ) -> RunStatus {
        if forceSkipped { return .skipped }
        if errorMessages.isEmpty { return .success }
        if portfolioResult == nil && optionEODResult == nil { return .failed }
        return .partial
    }
}

struct RunLogInput: Codable, Sendable {
    let runDate: Date
    let status: RunStatus
    let portfolioResult: FilteredPositionSet?
    let eodResult: EODPriceResult?
    let optionEODResult: OptionEODResult?
    let pricingResult: PricingResult?
    let errorMessages: [String]
    let startedAt: Date
    let completedAt: Date
}
