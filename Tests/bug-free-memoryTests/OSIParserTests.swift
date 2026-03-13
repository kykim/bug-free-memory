//
//  OSIParserTests.swift
//  bug-free-memory
//
//  TICKET-004: OSIParser unit tests
//

import Testing
import Foundation
@testable import bug_free_memory

@Suite("OSIParser")
struct OSIParserTests {

    // MARK: - Happy path

    @Test("Parses standard equity call — AAPL $175 2026-03-21")
    func equityCall() throws {
        let c = try OSIParser.parse("AAPL  260321C00175000")
        #expect(c.underlyingTicker == "AAPL")
        #expect(c.optionType == .call)
        #expect(c.strikePrice == 175.0)
        let parts = dateComponents(c.expirationDate)
        #expect(parts.year == 2026 && parts.month == 3 && parts.day == 21)
    }

    @Test("Parses standard equity put — SPY $450 2026-06-20")
    func equityPut() throws {
        let c = try OSIParser.parse("SPY   260620P00450000")
        #expect(c.underlyingTicker == "SPY")
        #expect(c.optionType == .put)
        #expect(c.strikePrice == 450.0)
    }

    @Test("Parses index call — SPX $5500 2026-12-18")
    func indexCall() throws {
        let c = try OSIParser.parse("SPX   261218C05500000")
        #expect(c.underlyingTicker == "SPX")
        #expect(c.optionType == .call)
        #expect(c.strikePrice == 5500.0)
    }

    @Test("Parses fractional strike — $123.456")
    func fractionalStrike() throws {
        // Strike field encodes cents: 123456 → $123.456
        let c = try OSIParser.parse("TSLA  260620C00123456")
        #expect(abs(c.strikePrice - 123.456) < 0.0001)
    }

    @Test("Strips right-padding spaces from ticker")
    func tickerPaddingStripped() throws {
        // 6-char ticker with no padding
        let c = try OSIParser.parse("GOOGL 260620C02000000")
        #expect(c.underlyingTicker == "GOOGL")
    }

    @Test("Parses full 6-char ticker with no padding")
    func sixCharTicker() throws {
        let c = try OSIParser.parse("GOOGLS260620C02000000")
        #expect(c.underlyingTicker == "GOOGLS")
    }

    @Test("Expiration date uses America/New_York timezone")
    func expirationDateTimezone() throws {
        let c = try OSIParser.parse("AAPL  260321C00175000")
        let nyTZ = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyTZ
        let comps = cal.dateComponents([.year, .month, .day], from: c.expirationDate)
        #expect(comps.year == 2026 && comps.month == 3 && comps.day == 21)
    }

    // MARK: - Error cases

    @Test("Throws invalidLength when string is too short")
    func tooShort() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL260321C00175000")   // 19 chars
        }
    }

    @Test("Throws invalidLength when string is too long")
    func tooLong() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL  260321C001750001")  // 22 chars
        }
    }

    @Test("Throws invalidLength for empty string")
    func emptyString() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("")
        }
    }

    @Test("Throws invalidOptionType for 'X'")
    func badOptionType() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL  260321X00175000")
        }
    }

    @Test("Throws invalidOptionType for digit in type position")
    func digitOptionType() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL  2603210001750000")
        }
    }

    @Test("Throws invalidStrike when strike field contains letters")
    func nonNumericStrike() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL  260321C001750XY")
        }
    }

    @Test("Throws invalidExpiryFormat for impossible date")
    func impossibleDate() {
        #expect(throws: OSIParseError.self) {
            try OSIParser.parse("AAPL  269999C00175000")   // month 99
        }
    }
}

// MARK: - Helpers

private func dateComponents(_ date: Date) -> DateComponents {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    return cal.dateComponents([.year, .month, .day], from: date)
}
