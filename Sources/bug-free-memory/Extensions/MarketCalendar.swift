//
//  MarketCalendar.swift
//  bug-free-memory
//
//  US market holiday calendar for 2026 and weekend detection.
//

import Foundation

enum MarketCalendar {

    private static let formatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    // 2026 US market holidays
    private static let holidays2026: Set<String> = [
        "20260101", // New Year's Day
        "20260119", // MLK Day
        "20260216", // Presidents' Day
        "20260403", // Good Friday
        "20260525", // Memorial Day
        "20260703", // Independence Day (observed)
        "20260907", // Labor Day
        "20261126", // Thanksgiving
        "20261225", // Christmas
    ]

    static func isHoliday(_ date: Date) -> Bool {
        let key = formatter.string(from: date)
        return holidays2026.contains(key)
    }

    static func isTradingDay(_ date: Date) -> Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let weekday = cal.component(.weekday, from: date)
        // weekday: 1=Sunday, 7=Saturday
        if weekday == 1 || weekday == 7 { return false }
        return !isHoliday(date)
    }
}
