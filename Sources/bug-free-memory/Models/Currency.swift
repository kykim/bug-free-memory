//
//  Currency.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

final class Currency: Model, Content, @unchecked Sendable {
    static let schema = "currencies"

    @ID(custom: "currency_code", generatedBy: .user)
    var id: String?

    @Field(key: "name")
    var name: String

    // Relations
    @Children(for: \.$currency)
    var instruments: [Instrument]

    init() {}

    init(currencyCode: String, name: String) {
        self.id = currencyCode
        self.name = name
    }
}
