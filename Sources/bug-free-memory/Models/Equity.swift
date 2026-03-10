//
//  Equity.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

final class Equity: Model, Content, @unchecked Sendable {
    static let schema = "equities"

    @ID(custom: "instrument_id", generatedBy: .user)
    var id: UUID?

    @OptionalField(key: "isin")
    var isin: String?

    @OptionalField(key: "cusip")
    var cusip: String?

    @OptionalField(key: "figi")
    var figi: String?

    @OptionalField(key: "sector")
    var sector: String?

    @OptionalField(key: "industry")
    var industry: String?

    @OptionalField(key: "shares_outstanding")
    var sharesOutstanding: Int?

    init() {}

    init(
        instrumentID: UUID,
        isin: String? = nil,
        cusip: String? = nil,
        figi: String? = nil,
        sector: String? = nil,
        industry: String? = nil,
        sharesOutstanding: Int? = nil
    ) {
        self.id = instrumentID
        self.isin = isin
        self.cusip = cusip
        self.figi = figi
        self.sector = sector
        self.industry = industry
        self.sharesOutstanding = sharesOutstanding
    }
    
    var ticker: String? {
        try? joined(Instrument.self).ticker
    }
}
