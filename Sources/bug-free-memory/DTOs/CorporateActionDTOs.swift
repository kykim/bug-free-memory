import Vapor

struct CreateCorporateActionDTO: Content, Validatable {
    var instrument_id: UUID
    var action_type: String
    var ex_date: String
    var record_date: String?
    var pay_date: String?
    var ratio: Double?
    var notes: String?

    static func validations(_ validations: inout Validations) {
        validations.add("action_type", as: String.self,
                        is: .in("split", "reverse_split", "dividend_cash", "dividend_stock",
                                "spinoff", "merger", "delisting"),
                        customFailureDescription: "Invalid action type")
        validations.add("ratio", as: Double.self, is: .range(0.000001...),
                        required: false,
                        customFailureDescription: "Ratio must be greater than zero")
    }

    var parsedActionType: CorporateActionType { CorporateActionType(rawValue: action_type)! }

    func parsedExDate() throws -> Date { try parseFormDate(ex_date) }
    func parsedRecordDate() throws -> Date? { try record_date.flatMap { try parseFormDate($0) } }
    func parsedPayDate() throws -> Date? { try pay_date.flatMap { try parseFormDate($0) } }
}

struct UpdateCorporateActionDTO: Content, Validatable {
    var ex_date: String
    var record_date: String?
    var pay_date: String?
    var ratio: Double?
    var notes: String?

    static func validations(_ validations: inout Validations) {
        validations.add("ratio", as: Double.self, is: .range(0.000001...),
                        required: false,
                        customFailureDescription: "Ratio must be greater than zero")
    }

    func parsedExDate() throws -> Date { try parseFormDate(ex_date) }
    func parsedRecordDate() throws -> Date? { try record_date.flatMap { try parseFormDate($0) } }
    func parsedPayDate() throws -> Date? { try pay_date.flatMap { try parseFormDate($0) } }
}
