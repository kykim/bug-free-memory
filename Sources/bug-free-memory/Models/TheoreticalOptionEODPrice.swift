//
//  TheoreticalOptionEODPrice.swift
//  bug-free-memory
//
//  Created for Kevin Y Kim on 3/11/26.
//
//  Stores theoretical (model-derived) EOD option prices alongside
//  the greeks and the model that produced them.
//

import Fluent
import Vapor

// MARK: - Pricing Model Enum

enum PricingModel: String, Codable, CaseIterable {
    case blackScholes  = "black_scholes"
    case binomial      = "binomial"
    case monteCarlo    = "monte_carlo"
}

// MARK: - Model

final class TheoreticalOptionEODPrice: Model, Content, @unchecked Sendable {
    static let schema = "theoretical_option_eod_prices"

    @ID
    var id: UUID?

    /// The option instrument this record belongs to.
    @Parent(key: "instrument_id")
    var instrument: Instrument

    /// The date this theoretical snapshot represents.
    @Field(key: "price_date")
    var priceDate: Date

    // MARK: Prices

    /// Model theoretical fair value (per share / per unit).
    @Field(key: "price")
    var price: Double

    /// Theoretical settlement price.
    /// Typically equal to `price` for European; may differ for American/Bermudan
    /// if the model determines early exercise is optimal.
    @OptionalField(key: "settlement_price")
    var settlementPrice: Double?

    // MARK: Volatility & Rate Inputs

    /// Implied volatility used or derived during pricing (annualised).
    @OptionalField(key: "implied_volatility")
    var impliedVolatility: Double?

    /// Historical volatility used as the sigma input (annualised).
    @Field(key: "historical_volatility")
    var historicalVolatility: Double

    /// Risk-free rate used in the calculation (annualised).
    @Field(key: "risk_free_rate")
    var riskFreeRate: Double

    /// Underlying spot price at time of calculation.
    @Field(key: "underlying_price")
    var underlyingPrice: Double

    // MARK: Greeks

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

    // MARK: Model Metadata

    /// Which pricing model produced this record.
    @Enum(key: "model")
    var model: PricingModel

    /// Human-readable label from the pricer (e.g. "Binomial CRR (American, 200 steps)").
    @OptionalField(key: "model_detail")
    var modelDetail: String?

    @OptionalField(key: "source")
    var source: String?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        instrumentID: UUID,
        priceDate: Date,
        price: Double,
        settlementPrice: Double? = nil,
        impliedVolatility: Double? = nil,
        historicalVolatility: Double,
        riskFreeRate: Double,
        underlyingPrice: Double,
        delta: Double? = nil,
        gamma: Double? = nil,
        theta: Double? = nil,
        vega: Double? = nil,
        rho: Double? = nil,
        model: PricingModel,
        modelDetail: String? = nil,
        source: String? = nil
    ) {
        self.id = id
        self.$instrument.id = instrumentID
        self.priceDate = priceDate
        self.price = price
        self.settlementPrice = settlementPrice
        self.impliedVolatility = impliedVolatility
        self.historicalVolatility = historicalVolatility
        self.riskFreeRate = riskFreeRate
        self.underlyingPrice = underlyingPrice
        self.delta = delta
        self.gamma = gamma
        self.theta = theta
        self.vega = vega
        self.rho = rho
        self.model = model
        self.modelDetail = modelDetail
        self.source = source
    }
}

// MARK: - Factory helpers (build from pricer output)

extension TheoreticalOptionEODPrice {

    /// Build a record from an `OptionPriceResult` (Black-Scholes or Binomial).
    static func from(
        result: OptionPriceResult,
        instrumentID: UUID,
        priceDate: Date,
        riskFreeRate: Double,
        pricingModel: PricingModel,
        source: String? = nil
    ) -> TheoreticalOptionEODPrice {
        TheoreticalOptionEODPrice(
            instrumentID:         instrumentID,
            priceDate:            priceDate,
            price:                result.price,
            settlementPrice:      result.price,
            impliedVolatility:    result.impliedVolatility,
            historicalVolatility: result.historicalVolatility,
            riskFreeRate:         riskFreeRate,
            underlyingPrice:      result.underlyingPrice,
            delta:                result.greeks.delta,
            gamma:                result.greeks.gamma,
            theta:                result.greeks.theta,
            vega:                 result.greeks.vega,
            rho:                  result.greeks.rho,
            model:                pricingModel,
            modelDetail:          result.model,
            source:               source
        )
    }

    /// Build a record from a `MonteCarloResult`.
    static func from(
        result: MonteCarloResult,
        instrumentID: UUID,
        priceDate: Date,
        riskFreeRate: Double,
        source: String? = nil
    ) -> TheoreticalOptionEODPrice {
        TheoreticalOptionEODPrice(
            instrumentID:         instrumentID,
            priceDate:            priceDate,
            price:                result.price,
            settlementPrice:      result.price,
            impliedVolatility:    nil,
            historicalVolatility: result.historicalVolatility,
            riskFreeRate:         riskFreeRate,
            underlyingPrice:      result.underlyingPrice,
            delta:                result.greeks?.delta,
            gamma:                result.greeks?.gamma,
            theta:                result.greeks?.theta,
            vega:                 result.greeks?.vega,
            rho:                  result.greeks?.rho,
            model:                .monteCarlo,
            modelDetail:          result.model,
            source:               source
        )
    }
}
