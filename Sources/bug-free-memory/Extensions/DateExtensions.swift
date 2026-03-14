import Foundation

extension Calendar {
    /// A Gregorian calendar pinned to UTC. Use for all price-date normalisation.
    static let utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}

extension DateFormatter {
    /// `yyyy-MM-dd` formatter in UTC, suitable for display of price dates.
    static let utcYMD: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")
        return df
    }()
}
