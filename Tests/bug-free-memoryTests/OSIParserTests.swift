//
//  OSIParserTests.swift
//  bug-free-memory
//
//  TICKET-018: Smoke test — OSIParser round-trip
//

import Testing
import Foundation
@testable import bug_free_memory

@Suite("OSIParser")
struct OSIParserTests {

    @Test("Parses AAPL call correctly")
    func testAAPLCall() throws {
        let components = try OSIParser.parse("AAPL  260321C00175000")
        #expect(components.underlyingTicker == "AAPL")
        #expect(components.optionType == .call)
        #expect(abs(components.strikePrice - 175.0) < 0.001)
        // Expiry should be 2026-03-21
        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: TimeZone(identifier: "America/New_York")!, from: components.expirationDate)
        #expect(comps.year == 2026)
        #expect(comps.month == 3)
        #expect(comps.day == 21)
    }

    @Test("Parses SPY put correctly")
    func testSPYPut() throws {
        let components = try OSIParser.parse("SPY   260620P00450000")
        #expect(components.underlyingTicker == "SPY")
        #expect(components.optionType == .put)
        #expect(abs(components.strikePrice - 450.0) < 0.001)
    }

    @Test("Parses SPX call correctly")
    func testSPXCall() throws {
        let components = try OSIParser.parse("SPX   261218C05500000")
        #expect(components.underlyingTicker == "SPX")
        #expect(components.optionType == .call)
        #expect(abs(components.strikePrice - 5500.0) < 0.001)
    }

    @Test("Throws invalidLength for short string")
    func testInvalidLength() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL")
        }
    }

    @Test("Throws invalidOptionType for unknown type char")
    func testInvalidOptionType() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL  260321X00175000")
        }
    }
}
