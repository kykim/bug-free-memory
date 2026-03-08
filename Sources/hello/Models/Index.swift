//
//  Index.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

final class Index: Model, Content, @unchecked Sendable {
    static let schema = "indexes"

    @ID(custom: "instrument_id", generatedBy: .user)
    var id: Int?

    @Parent(key: "instrument_id")
    var instrument: Instrument

    @OptionalField(key: "index_family")
    var indexFamily: String?

    @OptionalField(key: "methodology")
    var methodology: String?

    @OptionalField(key: "rebalance_freq")
    var rebalanceFreq: String?

    init() {}

    init(
        instrumentID: Int,
        indexFamily: String? = nil,
        methodology: String? = nil,
        rebalanceFreq: String? = nil
    ) {
        self.id = instrumentID
        self.$instrument.id = instrumentID
        self.indexFamily = indexFamily
        self.methodology = methodology
        self.rebalanceFreq = rebalanceFreq
    }
}
