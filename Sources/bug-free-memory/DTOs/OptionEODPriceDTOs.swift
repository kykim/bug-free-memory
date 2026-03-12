import Vapor

struct CreateOptionEODPriceDTO: Content, Validatable {
    var instrument_id: UUID
    var price_date: String
    var bid: Double?
    var ask: Double?
    var last: Double?
    var settlement_price: Double?
    var volume: Int?
    var open_interest: Int?
    var implied_volatility: Double?
    var delta: Double?
    var gamma: Double?
    var theta: Double?
    var vega: Double?
    var rho: Double?
    var underlying_price: Double?
    var risk_free_rate: Double?
    var dividend_yield: Double?
    var source: String?

    static func validations(_ validations: inout Validations) {
        validations.add("volume", as: Int.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Volume must be non-negative")
        validations.add("open_interest", as: Int.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Open interest must be non-negative")
        validations.add("implied_volatility", as: Double.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Implied volatility must be non-negative")
        validations.add("delta", as: Double.self, is: .range(-1.0...1.0),
                        required: false,
                        customFailureDescription: "Delta must be between -1 and 1")
        validations.add("gamma", as: Double.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Gamma must be non-negative")
    }

    func parsedPriceDate() throws -> Date {
        try parseFormDate(price_date)
    }
}

struct UpdateOptionEODPriceDTO: Content, Validatable {
    var bid: Double?
    var ask: Double?
    var last: Double?
    var settlement_price: Double?
    var volume: Int?
    var open_interest: Int?
    var implied_volatility: Double?
    var delta: Double?
    var gamma: Double?
    var theta: Double?
    var vega: Double?
    var rho: Double?
    var underlying_price: Double?
    var risk_free_rate: Double?
    var dividend_yield: Double?
    var source: String?

    static func validations(_ validations: inout Validations) {
        validations.add("volume", as: Int.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Volume must be non-negative")
        validations.add("open_interest", as: Int.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Open interest must be non-negative")
        validations.add("implied_volatility", as: Double.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Implied volatility must be non-negative")
        validations.add("delta", as: Double.self, is: .range(-1.0...1.0),
                        required: false,
                        customFailureDescription: "Delta must be between -1 and 1")
        validations.add("gamma", as: Double.self, is: .range(0...),
                        required: false,
                        customFailureDescription: "Gamma must be non-negative")
    }
}
