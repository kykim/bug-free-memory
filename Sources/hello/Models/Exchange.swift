//
//  Exchange.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

final class Exchange: Model, Content, @unchecked Sendable {
    static let schema = "exchanges"

    @ID
    var id: UUID?

    @Field(key: "mic_code")
    var micCode: String

    @Field(key: "name")
    var name: String

    @Field(key: "country_code")
    var countryCode: String

    @Field(key: "timezone")
    var timezone: String

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    // Relations
    @Children(for: \.$exchange)
    var instruments: [Instrument]

    init() {}

    init(id: UUID? = nil, micCode: String, name: String, countryCode: String, timezone: String) {
        self.id = id
        self.micCode = micCode
        self.name = name
        self.countryCode = countryCode
        self.timezone = timezone
    }
}
