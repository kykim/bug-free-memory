//
//  YieldCurveTests.swift
//  bug-free-memory
//
//  TICKET-019: Smoke test — YieldCurve.interpolate unit tests
//

import Testing
import Foundation
@testable import bug_free_memory

@Suite("YieldCurve.interpolate")
struct YieldCurveTests {

    private func makePoint(tenor: Double, rate: Double) -> YieldCurve.Point {
        YieldCurve.Point(tenorYears: tenor, continuousRate: rate)
    }

    private func makeCurve(_ points: [YieldCurve.Point]) -> YieldCurve {
        YieldCurve(points: points, observationDate: Date())
    }

    @Test("Empty curve returns 0.05 fallback")
    func testEmptyCurveFallback() {
        let curve = makeCurve([])
        #expect(curve.interpolate(timeToExpiry: 1.0) == 0.05)
    }

    @Test("Single point returns that rate regardless of T")
    func testSinglePoint() {
        let curve = makeCurve([makePoint(tenor: 1.0, rate: 0.04)])
        #expect(curve.interpolate(timeToExpiry: 0.5) == 0.04)
        #expect(curve.interpolate(timeToExpiry: 1.0) == 0.04)
        #expect(curve.interpolate(timeToExpiry: 2.0) == 0.04)
    }

    @Test("Linear interpolation between two points at midpoint")
    func testLinearInterpolation() {
        let curve = makeCurve([
            makePoint(tenor: 1.0, rate: 0.04),
            makePoint(tenor: 2.0, rate: 0.06),
        ])
        let result = curve.interpolate(timeToExpiry: 1.5)
        #expect(abs(result - 0.05) < 1e-10)
    }

    @Test("Flat extrapolation below shortest tenor")
    func testFlatExtrapolationBelow() {
        let curve = makeCurve([
            makePoint(tenor: 1.0, rate: 0.04),
            makePoint(tenor: 2.0, rate: 0.06),
        ])
        let result = curve.interpolate(timeToExpiry: 0.25)
        #expect(result == 0.04)
    }

    @Test("Flat extrapolation above longest tenor")
    func testFlatExtrapolationAbove() {
        let curve = makeCurve([
            makePoint(tenor: 1.0, rate: 0.04),
            makePoint(tenor: 2.0, rate: 0.06),
        ])
        let result = curve.interpolate(timeToExpiry: 5.0)
        #expect(result == 0.06)
    }
}
