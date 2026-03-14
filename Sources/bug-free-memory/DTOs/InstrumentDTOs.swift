import Vapor

struct CreateInstrumentDTO: Content, Validatable {
    var instrument_type: String
    var ticker: String
    var name: String
    var exchange_id: UUID?
    var currency_code: String
    var is_active: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        instrument_type = try c.decode(String.self, forKey: .instrument_type)
        ticker          = try c.decode(String.self, forKey: .ticker)
        name            = try c.decode(String.self, forKey: .name)
        currency_code   = try c.decode(String.self, forKey: .currency_code)
        is_active       = try c.decodeIfPresent(String.self, forKey: .is_active)
        let raw         = try c.decodeIfPresent(String.self, forKey: .exchange_id)
        exchange_id     = raw.flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
    }

    static func validations(_ validations: inout Validations) {
        validations.add("instrument_type", as: String.self,
                        is: .in("equity", "index", "equity_option", "index_option"),
                        customFailureDescription: "Must be equity, index, equity_option, or index_option")
        validations.add("ticker", as: String.self, is: .count(1...50),
                        customFailureDescription: "Ticker must be 1–50 characters")
        validations.add("name", as: String.self, is: .count(1...200),
                        customFailureDescription: "Name must be 1–200 characters")
        validations.add("currency_code", as: String.self, is: .count(3...3),
                        customFailureDescription: "Currency code must be exactly 3 characters")
    }

    var parsedInstrumentType: InstrumentType { InstrumentType(rawValue: instrument_type)! }
}

struct UpdateInstrumentDTO: Content, Validatable {
    var name: String
    var exchange_id: UUID?
    var currency_code: String
    var is_active: String?

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name          = try c.decode(String.self, forKey: .name)
        currency_code = try c.decode(String.self, forKey: .currency_code)
        is_active     = try c.decodeIfPresent(String.self, forKey: .is_active)
        let raw       = try c.decodeIfPresent(String.self, forKey: .exchange_id)
        exchange_id   = raw.flatMap { $0.isEmpty ? nil : UUID(uuidString: $0) }
    }

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1...200),
                        customFailureDescription: "Name must be 1–200 characters")
        validations.add("currency_code", as: String.self, is: .count(3...3),
                        customFailureDescription: "Currency code must be exactly 3 characters")
    }
}
