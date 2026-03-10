//
//  OptionContract.swift
//  hello
//
//  Created by Kevin Y Kim on 3/7/26.
//


import Fluent
import Vapor

enum OptionType: String, Codable {
    case call
    case put
}

enum ExerciseStyle: String, Codable {
    case american
    case european
    case bermudan
}

final class OptionContract: Model, Content, @unchecked Sendable {
    static let schema = "option_contracts"

    @ID(custom: "instrument_id", generatedBy: .user)
    var id: UUID?

    @Parent(key: "instrument_id")
    var instrument: Instrument

    @Parent(key: "underlying_id")
    var underlying: Instrument

    @Enum(key: "option_type")
    var optionType: OptionType

    @Enum(key: "exercise_style")
    var exerciseStyle: ExerciseStyle

    @Field(key: "strike_price")
    var strikePrice: Double

    @Field(key: "expiration_date")
    var expirationDate: Date

    @Field(key: "contract_multiplier")
    var contractMultiplier: Double

    @Field(key: "settlement_type")
    var settlementType: String

    @OptionalField(key: "osi_symbol")
    var osiSymbol: String?

    init() {}

    init(
        instrumentID: UUID,
        underlyingID: UUID,
        optionType: OptionType,
        exerciseStyle: ExerciseStyle,
        strikePrice: Double,
        expirationDate: Date,
        contractMultiplier: Double = 100,
        settlementType: String = "physical",
        osiSymbol: String? = nil
    ) {
        self.id = instrumentID
        self.$instrument.id = instrumentID
        self.$underlying.id = underlyingID
        self.optionType = optionType
        self.exerciseStyle = exerciseStyle
        self.strikePrice = strikePrice
        self.expirationDate = expirationDate
        self.contractMultiplier = contractMultiplier
        self.settlementType = settlementType
        self.osiSymbol = osiSymbol
    }
}
