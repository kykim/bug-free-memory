//
//  EODPrice.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

final class EODPrice: Model, Content, @unchecked Sendable {
    static let schema = "eod_prices"

    @ID(custom: "eod_price_id", generatedBy: .database)
    var id: Int?

    @Parent(key: "instrument_id")
    var instrument: Instrument

    @Field(key: "price_date")
    var priceDate: Date

    @OptionalField(key: "open")
    var open: Double?

    @OptionalField(key: "high")
    var high: Double?

    @OptionalField(key: "low")
    var low: Double?

    @Field(key: "close")
    var close: Double

    @OptionalField(key: "adj_close")
    var adjClose: Double?

    @OptionalField(key: "volume")
    var volume: Int?

    @OptionalField(key: "vwap")
    var vwap: Double?

    @OptionalField(key: "source")
    var source: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: Int? = nil,
        instrumentID: Int,
        priceDate: Date,
        open: Double? = nil,
        high: Double? = nil,
        low: Double? = nil,
        close: Double,
        adjClose: Double? = nil,
        volume: Int? = nil,
        vwap: Double? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.$instrument.id = instrumentID
        self.priceDate = priceDate
        self.open = open
        self.high = high
        self.low = low
        self.close = close
        self.adjClose = adjClose
        self.volume = volume
        self.vwap = vwap
        self.source = source
    }
}
