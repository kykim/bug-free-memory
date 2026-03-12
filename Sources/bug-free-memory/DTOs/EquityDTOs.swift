import Vapor

struct CreateEquityDTO: Content {
    var instrument_id: UUID
    var isin: String?
    var cusip: String?
    var figi: String?
    var sector: String?
    var industry: String?
    var shares_outstanding: Int?
}

struct UpdateEquityDTO: Content {
    var isin: String?
    var cusip: String?
    var figi: String?
    var sector: String?
    var industry: String?
    var shares_outstanding: Int?
}
