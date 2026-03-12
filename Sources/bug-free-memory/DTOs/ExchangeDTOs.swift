import Vapor

struct CreateExchangeDTO: Content, Validatable {
    var mic_code: String
    var name: String
    var country_code: String
    var timezone: String

    static func validations(_ validations: inout Validations) {
        validations.add("mic_code", as: String.self, is: .count(1...4),
                        customFailureDescription: "MIC code must be 1–4 characters")
        validations.add("name", as: String.self, is: .count(1...),
                        customFailureDescription: "Name is required")
        validations.add("country_code", as: String.self, is: .count(2...2),
                        customFailureDescription: "Country code must be exactly 2 characters (ISO 3166-1 alpha-2)")
        validations.add("timezone", as: String.self, is: .count(1...),
                        customFailureDescription: "Timezone is required")
    }
}

struct UpdateExchangeDTO: Content, Validatable {
    var name: String
    var country_code: String
    var timezone: String

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: .count(1...),
                        customFailureDescription: "Name is required")
        validations.add("country_code", as: String.self, is: .count(2...2),
                        customFailureDescription: "Country code must be exactly 2 characters (ISO 3166-1 alpha-2)")
        validations.add("timezone", as: String.self, is: .count(1...),
                        customFailureDescription: "Timezone is required")
    }
}
