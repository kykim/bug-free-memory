//
//  YieldCurve.swift
//  bug-free-memory
//
//  Value type for risk-free rate interpolation from FRED yield data.
//

import Fluent
import Foundation
import FluentSQL

struct YieldCurve: Sendable {

    struct Point: Sendable {
        let tenorYears: Double
        let continuousRate: Double
    }

    /// Yield curve points sorted ascending by tenorYears.
    let points: [Point]
    let observationDate: Date

    // MARK: - Load

    /// Loads the most recent yield curve on or before runDate from fred_yields.
    static func load(db: any Database, runDate: Date) async throws -> YieldCurve {
        // Find MAX(observation_date) <= runDate
        let sqlDB = db as! any SQLDatabase

        struct DateRow: Decodable {
            let observation_date: Date?
        }

        // Use Fluent query to find the max observation date on or before runDate
        let row = try await FREDYield.query(on: db)
            .filter(\.$observationDate <= runDate)
            .sort(\.$observationDate, .descending)
            .first()

        guard let observationDate = row?.observationDate else {
            return YieldCurve(points: [], observationDate: runDate)
        }

        // Start/end of that day
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let start = cal.startOfDay(for: observationDate)
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else {
            return YieldCurve(points: [], observationDate: runDate)
        }

        let yields = try await FREDYield.query(on: db)
            .filter(\.$observationDate >= start)
            .filter(\.$observationDate < end)
            .sort(\.$tenorYears, .ascending)
            .all()

        let pts = yields.compactMap { y -> Point? in
            guard let rate = y.continuousRate else { return nil }
            return Point(tenorYears: y.tenorYears, continuousRate: rate)
        }

        return YieldCurve(points: pts, observationDate: observationDate)
    }

    // MARK: - Interpolate

    /// Returns the continuously compounded rate for the given time to expiry.
    func interpolate(timeToExpiry: Double) -> Double {
        guard !points.isEmpty else { return 0.05 }
        guard points.count > 1 else { return points[0].continuousRate }

        // Flat extrapolation at lower bound
        if timeToExpiry <= points.first!.tenorYears {
            return points.first!.continuousRate
        }
        // Flat extrapolation at upper bound
        if timeToExpiry >= points.last!.tenorYears {
            return points.last!.continuousRate
        }
        // Linear interpolation
        let lo = points.last  { $0.tenorYears <= timeToExpiry }!
        let hi = points.first { $0.tenorYears >  timeToExpiry }!
        let w = (timeToExpiry - lo.tenorYears) / (hi.tenorYears - lo.tenorYears)
        return lo.continuousRate + w * (hi.continuousRate - lo.continuousRate)
    }
}
