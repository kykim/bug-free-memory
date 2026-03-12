//
//  FREDYield.swift
//  bug-free-memory
//
//  Created for Kevin Y Kim on 3/11/26.
//
//  Stores daily Federal Reserve H.15 yield observations from FRED
//  for the key Treasury tenors used in option risk-free rate calculation.
//

import Fluent
import Vapor

// MARK: - Tenor Enum

enum FREDSeries: String, Codable, CaseIterable {
    case oneMonth  = "DGS1MO"
    case threeMonth = "DGS3MO"
    case sixMonth  = "DGS6MO"
    case oneYear   = "DGS1"
    case twoYear   = "DGS2"
    case fiveYear  = "DGS5"

    /// Approximate tenor in years — used for interpolation.
    var tenorYears: Double {
        switch self {
        case .oneMonth:   return 1.0 / 12.0
        case .threeMonth: return 3.0 / 12.0
        case .sixMonth:   return 6.0 / 12.0
        case .oneYear:    return 1.0
        case .twoYear:    return 2.0
        case .fiveYear:   return 5.0
        }
    }

    /// Human-readable label.
    var label: String {
        switch self {
        case .oneMonth:   return "1-Month Treasury"
        case .threeMonth: return "3-Month Treasury"
        case .sixMonth:   return "6-Month Treasury"
        case .oneYear:    return "1-Year Treasury"
        case .twoYear:    return "2-Year Treasury"
        case .fiveYear:   return "5-Year Treasury"
        }
    }
}

// MARK: - Model

final class FREDYield: Model, Content, @unchecked Sendable {
    static let schema = "fred_yields"

    @ID
    var id: UUID?

    /// FRED series identifier (e.g. "DGS3MO").
    @Enum(key: "series_id")
    var seriesID: FREDSeries

    /// The observation date this yield applies to.
    @Field(key: "observation_date")
    var observationDate: Date

    /// Raw annualised yield as published by FRED, in percent (e.g. 5.25 = 5.25%).
    /// FRED occasionally publishes "." for missing/holiday values — store as nil.
    @OptionalField(key: "yield_percent")
    var yieldPercent: Double?

    /// Continuously compounded rate derived from `yieldPercent`.
    /// r = ln(1 + yieldPercent / 100). Nil when yieldPercent is nil.
    @OptionalField(key: "continuous_rate")
    var continuousRate: Double?

    /// Tenor in years for this series, denormalised for query convenience.
    @Field(key: "tenor_years")
    var tenorYears: Double

    @OptionalField(key: "source")
    var source: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        seriesID: FREDSeries,
        observationDate: Date,
        yieldPercent: Double?,
        source: String? = "FRED"
    ) {
        self.id = id
        self.seriesID = seriesID
        self.observationDate = observationDate
        self.yieldPercent = yieldPercent
        self.continuousRate = yieldPercent.map { log(1 + $0 / 100) }
        self.tenorYears = seriesID.tenorYears
        self.source = source
    }
}
