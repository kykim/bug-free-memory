import Vapor

struct CreateEODPriceDTO: Content, Validatable {
    var instrument_id: UUID
    var price_date: String
    var open: Double?
    var high: Double?
    var low: Double?
    var close: Double
    var adj_close: Double?
    var volume: Int?
    var vwap: Double?
    var source: String?

    static func validations(_ validations: inout Validations) {
        validations.add("volume", as: Int.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Volume must be non-negative")
    }

    func parsedPriceDate() throws -> Date {
        try parseFormDate(price_date)
    }
}

struct UpdateEODPriceDTO: Content, Validatable {
    var open: Double?
    var high: Double?
    var low: Double?
    var close: Double
    var adj_close: Double?
    var volume: Int?
    var vwap: Double?
    var source: String?

    static func validations(_ validations: inout Validations) {
        validations.add("volume", as: Int.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Volume must be non-negative")
    }
}
