//
//  OSIParser.swift
//  bug-free-memory
//
//  Parses 21-character OSI option symbols.
//  Format: 6-char underlying (right-padded), 6-char YYMMDD, 1-char C/P, 8-char strike×1000.
//

import Foundation

enum OSIParseError: Error {
    case invalidLength(actual: Int)
    case invalidExpiryFormat(String)
    case invalidOptionType(Character)
    case invalidStrike(String)
}

struct OSIComponents: Sendable {
    let underlyingTicker: String
    let expirationDate: Date
    let optionType: OptionType
    let strikePrice: Double
}

enum OSIParser {

    private static let expiryFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    static func parse(_ osi: String) throws -> OSIComponents {
        guard osi.count == 21 else {
            throw OSIParseError.invalidLength(actual: osi.count)
        }

        let chars = Array(osi)

        // Characters 0–5: underlying ticker (trimming right-padding spaces)
        let tickerRaw = String(chars[0..<6])
        let ticker = tickerRaw.trimmingCharacters(in: .whitespaces)

        // Characters 6–11: expiry YYMMDD
        let expiryStr = String(chars[6..<12])
        guard let expirationDate = expiryFormatter.date(from: expiryStr) else {
            throw OSIParseError.invalidExpiryFormat(expiryStr)
        }

        // Character 12: C or P
        let typeChar = chars[12]
        let optionType: OptionType
        switch typeChar {
        case "C": optionType = .call
        case "P": optionType = .put
        default:  throw OSIParseError.invalidOptionType(typeChar)
        }

        // Characters 13–20: strike × 1000, zero-padded to 8 digits
        let strikeStr = String(chars[13..<21])
        guard let strikeRaw = Int(strikeStr) else {
            throw OSIParseError.invalidStrike(strikeStr)
        }
        let strikePrice = Double(strikeRaw) / 1000.0

        return OSIComponents(
            underlyingTicker: ticker,
            expirationDate: expirationDate,
            optionType: optionType,
            strikePrice: strikePrice
        )
    }
}
