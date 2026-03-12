import Vapor

struct CreateIndexDTO: Content {
    var instrument_id: UUID
    var index_family: String?
    var methodology: String?
    var rebalance_freq: String?
}

struct UpdateIndexDTO: Content {
    var index_family: String?
    var methodology: String?
    var rebalance_freq: String?
}
