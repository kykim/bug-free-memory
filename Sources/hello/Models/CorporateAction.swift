//
//  CorporateAction.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

enum CorporateActionType: String, Codable {
    case split
    case reverseSplit     = "reverse_split"
    case dividendCash     = "dividend_cash"
    case dividendStock    = "dividend_stock"
    case spinoff
    case merger
    case delisting
}

final class CorporateAction: Model, Content, @unchecked Sendable {
    static let schema = "corporate_actions"

    @ID(custom: "action_id", generatedBy: .database)
    var id: Int?

    @Parent(key: "instrument_id")
    var instrument: Instrument

    @Enum(key: "action_type")
    var actionType: CorporateActionType

    @Field(key: "ex_date")
    var exDate: Date

    @OptionalField(key: "record_date")
    var recordDate: Date?

    @OptionalField(key: "pay_date")
    var payDate: Date?

    @OptionalField(key: "ratio")
    var ratio: Double?

    @OptionalField(key: "notes")
    var notes: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: Int? = nil,
        instrumentID: Int,
        actionType: CorporateActionType,
        exDate: Date,
        recordDate: Date? = nil,
        payDate: Date? = nil,
        ratio: Double? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.$instrument.id = instrumentID
        self.actionType = actionType
        self.exDate = exDate
        self.recordDate = recordDate
        self.payDate = payDate
        self.ratio = ratio
        self.notes = notes
    }
}
