import Vapor

struct CreateCurrencyDTO: Content, Validatable {
    var currency_code: String
    var name: String

    static func validations(_ validations: inout Validations) {
        validations.add("currency_code", as: String.self, is: .count(3...3),
                        customFailureDescription: "Currency code must be exactly 3 characters (ISO 4217)")
        validations.add("name", as: String.self, is: .count(1...),
                        customFailureDescription: "Name is required")
    }
}

struct UpdateCurrencyDTO: Content, Validatable {
    var name: String

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1...),
                        customFailureDescription: "Name is required")
    }
}
