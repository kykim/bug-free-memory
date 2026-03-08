//
//  OptionEODPrice.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

final class OptionEODPrice: Model, Content, @unchecked Sendable {
    static let schema = "option_eod_prices"

    @ID(custom: "option_eod_id", generatedBy: .database)
    var id: Int?

    @Parent(key: "instrument_id")
    var instrument: Instrument

    @Field(key: "price_date")
    var priceDate: Date

    @OptionalField(key: "bid")
    var bid: Double?

    @OptionalField(key: "ask")
    var ask: Double?

    @OptionalField(key: "last")
    var last: Double?

    @OptionalField(key: "settlement_price")
    var settlementPrice: Double?

    @OptionalField(key: "volume")
    var volume: Int?

    @OptionalField(key: "open_interest")
    var openInterest: Int?

    @OptionalField(key: "implied_volatility")
    var impliedVolatility: Double?

    @OptionalField(key: "delta")
    var delta: Double?

    @OptionalField(key: "gamma")
    var gamma: Double?

    @OptionalField(key: "theta")
    var theta: Double?

    @OptionalField(key: "vega")
    var vega: Double?

    @OptionalField(key: "rho")
    var rho: Double?

    @OptionalField(key: "underlying_price")
    var underlyingPrice: Double?

    @OptionalField(key: "risk_free_rate")
    var riskFreeRate: Double?

    @OptionalField(key: "dividend_yield")
    var dividendYield: Double?

    @OptionalField(key: "source")
    var source: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    // mid is a computed column in Postgres — expose as a computed Swift property
    var mid: Double? {
        guard let bid, let ask else { return nil }
        return (bid + ask) / 2.0
    }

    init() {}

    init(
        id: Int? = nil,
        instrumentID: Int,
        priceDate: Date,
        bid: Double? = nil,
        ask: Double? = nil,
        last: Double? = nil,
        settlementPrice: Double? = nil,
        volume: Int? = nil,
        openInterest: Int? = nil,
        impliedVolatility: Double? = nil,
        delta: Double? = nil,
        gamma: Double? = nil,
        theta: Double? = nil,
        vega: Double? = nil,
        rho: Double? = nil,
        underlyingPrice: Double? = nil,
        riskFreeRate: Double? = nil,
        dividendYield: Double? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.$instrument.id = instrumentID
        self.priceDate = priceDate
        self.bid = bid
        self.ask = ask
        self.last = last
        self.settlementPrice = settlementPrice
        self.volume = volume
        self.openInterest = openInterest
        self.impliedVolatility = impliedVolatility
        self.delta = delta
        self.gamma = gamma
        self.theta = theta
        self.vega = vega
        self.rho = rho
        self.underlyingPrice = underlyingPrice
        self.riskFreeRate = riskFreeRate
        self.dividendYield = dividendYield
        self.source = source
    }
}
