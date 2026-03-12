import Vapor

struct CreateOptionContractDTO: Content, Validatable {
    var instrument_id: UUID
    var underlying_id: UUID
    var option_type: String
    var exercise_style: String
    var strike_price: Double
    var expiration_date: String
    var contract_multiplier: Double?
    var settlement_type: String?
    var osi_symbol: String?

    static func validations(_ validations: inout Validations) {
        validations.add("option_type", as: String.self, is: .in("call", "put"),
                        customFailureDescription: "Must be 'call' or 'put'")
        validations.add("exercise_style", as: String.self,
                        is: .in("american", "european", "bermudan"),
                        customFailureDescription: "Must be 'american', 'european', or 'bermudan'")
        validations.add("strike_price", as: Double.self, is: .range(0.000001...),
                        customFailureDescription: "Strike price must be greater than zero")
        validations.add("contract_multiplier", as: Double.self, is: .range(0.000001...),
                        required: false,
                        customFailureDescription: "Contract multiplier must be greater than zero")
    }

    var parsedOptionType: OptionType { OptionType(rawValue: option_type)! }
    var parsedExerciseStyle: ExerciseStyle { ExerciseStyle(rawValue: exercise_style)! }

    func parsedExpirationDate() throws -> Date {
        let date = try parseFormDate(expiration_date)
        guard date > Date() else {
            throw AppError.expirationDateInPast
        }
        return date
    }
}

struct UpdateOptionContractDTO: Content, Validatable {
    var strike_price: Double
    var expiration_date: String
    var contract_multiplier: Double
    var settlement_type: String
    var osi_symbol: String?

    static func validations(_ validations: inout Validations) {
        validations.add("strike_price", as: Double.self, is: .range(0.000001...),
                        customFailureDescription: "Strike price must be greater than zero")
        validations.add("contract_multiplier", as: Double.self, is: .range(0.000001...),
                        customFailureDescription: "Contract multiplier must be greater than zero")
    }

    func parsedExpirationDate() throws -> Date {
        try parseFormDate(expiration_date)
    }
}
