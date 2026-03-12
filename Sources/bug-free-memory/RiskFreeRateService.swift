//
//  RiskFreeRateService.swift
//  bug-free-memory
//
//  Created for Kevin Y Kim on 3/11/26.
//
//  Interpolates a continuously compounded risk-free rate for a given
//  observation date and time-to-expiry from cached FREDYield records.
//
//  Interpolation strategy:
//    - Exact tenor match          → use directly
//    - Between two known tenors   → linear interpolation
//    - Below shortest tenor       → use shortest available
//    - Above longest tenor        → use longest available (flat extrapolation)
//    - No yields for date         → walk back up to `maxLookbackDays` to find
//                                   the most recent trading day with data
//

import Fluent
import Vapor

// MARK: - Errors

enum RiskFreeRateError: Error, AbortError {
    case noYieldsFound(date: Date)
    case allYieldsMissing(date: Date)

    var status: HTTPResponseStatus { .unprocessableEntity }

    var reason: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        switch self {
        case .noYieldsFound(let d):
            return "No FRED yield data found on or before \(fmt.string(from: d))"
        case .allYieldsMissing(let d):
            return "FRED yields for \(fmt.string(from: d)) are all nil (holiday/weekend gap too large)"
        }
    }
}

// MARK: - Result

struct RiskFreeRateResult {
    /// Continuously compounded rate (e.g. 0.0512 = 5.12%).
    let continuousRate: Double
    /// Annualised yield in percent as published by FRED.
    let yieldPercent: Double
    /// The observation date the yields were sourced from.
    let observationDate: Date
    /// The time-to-expiry (years) this rate was interpolated for.
    let timeToExpiry: Double
    /// The two tenors that were interpolated between, if applicable.
    let interpolatedBetween: (lo: FREDSeries, hi: FREDSeries)?
}

// MARK: - Service

struct RiskFreeRateService {

    let db: any Database

    /// Maximum number of calendar days to look back when the requested
    /// date has no FRED data (weekends, holidays).
    var maxLookbackDays: Int = 7

    // MARK: - Public

    /// Returns an interpolated continuously compounded risk-free rate.
    ///
    /// - Parameters:
    ///   - date: The observation date (typically the pricing date).
    ///   - timeToExpiry: Option time-to-expiry in years — used to pick and
    ///                   interpolate the appropriate point on the yield curve.
    func rate(for date: Date, timeToExpiry: Double) async throws -> RiskFreeRateResult {
        let yields = try await _fetchYields(on: date)
        return try _interpolate(yields: yields, timeToExpiry: timeToExpiry, observationDate: date)
    }

    // MARK: - Private: Fetch

    /// Loads all non-nil FREDYield rows for the most recent available date
    /// on or before `date`, walking back up to `maxLookbackDays` if needed.
    private func _fetchYields(on date: Date) async throws -> [FREDYield] {
        let calendar = Calendar(identifier: .gregorian)

        for dayOffset in 0...maxLookbackDays {
            guard let target = calendar.date(byAdding: .day, value: -dayOffset, to: date) else { continue }
            let start = calendar.startOfDay(for: target)
            guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { continue }

            let rows = try await FREDYield.query(on: db)
                .filter(\.$observationDate >= start)
                .filter(\.$observationDate < end)
                .filter(\.$continuousRate != nil)
                .sort(\.$tenorYears)
                .all()

            if !rows.isEmpty { return rows }
        }

        throw RiskFreeRateError.noYieldsFound(date: date)
    }

    // MARK: - Private: Interpolation

    private func _interpolate(
        yields: [FREDYield],
        timeToExpiry: Double,
        observationDate: Date
    ) throws -> RiskFreeRateResult {

        // Extract valid (tenor, rate, yield%) points, sorted ascending by tenor
        let points: [(tenor: Double, rate: Double, yieldPct: Double, series: FREDSeries)] = yields
            .compactMap { y in
                guard let rate = y.continuousRate, let pct = y.yieldPercent else { return nil }
                return (y.tenorYears, rate, pct, y.seriesID)
            }
            .sorted { $0.tenor < $1.tenor }

        guard !points.isEmpty else {
            throw RiskFreeRateError.allYieldsMissing(date: observationDate)
        }

        // Exact match
        if let exact = points.first(where: { $0.tenor == timeToExpiry }) {
            return RiskFreeRateResult(
                continuousRate: exact.rate,
                yieldPercent: exact.yieldPct,
                observationDate: observationDate,
                timeToExpiry: timeToExpiry,
                interpolatedBetween: nil
            )
        }

        // Below shortest tenor — flat extrapolation from shortest
        if timeToExpiry <= points.first!.tenor {
            let p = points.first!
            return RiskFreeRateResult(
                continuousRate: p.rate,
                yieldPercent: p.yieldPct,
                observationDate: observationDate,
                timeToExpiry: timeToExpiry,
                interpolatedBetween: nil
            )
        }

        // Above longest tenor — flat extrapolation from longest
        if timeToExpiry >= points.last!.tenor {
            let p = points.last!
            return RiskFreeRateResult(
                continuousRate: p.rate,
                yieldPercent: p.yieldPct,
                observationDate: observationDate,
                timeToExpiry: timeToExpiry,
                interpolatedBetween: nil
            )
        }

        // Linear interpolation between the two bracketing tenors
        let lo = points.last  { $0.tenor <= timeToExpiry }!
        let hi = points.first { $0.tenor >  timeToExpiry }!
        let w  = (timeToExpiry - lo.tenor) / (hi.tenor - lo.tenor)

        return RiskFreeRateResult(
            continuousRate: lo.rate + w * (hi.rate - lo.rate),
            yieldPercent:   lo.yieldPct + w * (hi.yieldPct - lo.yieldPct),
            observationDate: observationDate,
            timeToExpiry: timeToExpiry,
            interpolatedBetween: (lo: lo.series, hi: hi.series)
        )
    }
}

// MARK: - Application extension for dependency injection

extension Application {
    var riskFreeRateService: RiskFreeRateService {
        RiskFreeRateService(db: self.db)
    }
}

extension Request {
    var riskFreeRateService: RiskFreeRateService {
        RiskFreeRateService(db: self.db)
    }
}
