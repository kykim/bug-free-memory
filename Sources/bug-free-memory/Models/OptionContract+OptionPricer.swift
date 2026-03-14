//
//  OptionContract+OptionPricer.swift
//  bug-free-memory
//
//  Created for Kevin Y Kim on 3/10/26.
//
//  Option pricing as an extension on OptionContract.
//  Supports Black-Scholes (European) and Binomial CRR (European + American).
//  All greeks included: Delta, Gamma, Theta, Vega, Rho.
//

import Fluent
import Vapor

// MARK: - Output Types

struct Greeks: Content {
    let delta: Double    // dV/dS
    let gamma: Double    // d²V/dS²
    let theta: Double    // dV/dt — per calendar day
    let vega: Double     // dV/dσ — per 1% move in vol
    let rho: Double      // dV/dr — per 1% move in rate
}

struct OptionPriceResult: Content {
    let price: Double                       // Per-share theoretical value
    let contractValue: Double               // price × contractMultiplier
    let greeks: Greeks
    let impliedVolatility: Double?          // Populated when marketPrice is supplied
    let model: String
    let underlyingPrice: Double
    let timeToExpiry: Double                // In years
    let historicalVolatility: Double
}

// MARK: - Volatility Method

/// Selects which historical volatility estimator to use when pricing an option.
enum VolatilityMethod {
    /// Equal-weighted log-return standard deviation over `lookback` trading days, annualised via √252.
    case historical(lookback: Int)
    /// RiskMetrics EWMA: σ²_t = λ·σ²_{t-1} + (1-λ)·r²_t, annualised via √252.
    /// Typical decay factor for daily equity data: λ = 0.94.
    /// More recent returns receive exponentially higher weight; effective half-life ≈ log(0.5)/log(λ) days.
    case ewma(lambda: Double)
}

// MARK: - Math Helpers (private)

private enum MathHelpers {

    /// Cumulative standard normal distribution via Hart approximation.
    static func normalCDF(_ x: Double) -> Double {
        let a1 =  0.254829592, a2 = -0.284496736, a3 =  1.421413741
        let a4 = -1.453152027, a5 =  1.061405429, p  =  0.3275911
        let sign: Double = x < 0 ? -1 : 1
        let t = 1.0 / (1.0 + p * abs(x))
        let poly = t * (a1 + t * (a2 + t * (a3 + t * (a4 + t * a5))))
        let result = 1.0 - poly * exp(-x * x / 2) / sqrt(2 * .pi)
        return 0.5 * (1.0 + sign * (2 * result - 1))
    }

    /// Standard normal PDF.
    static func normalPDF(_ x: Double) -> Double {
        exp(-0.5 * x * x) / sqrt(2 * .pi)
    }
}

// MARK: - OptionContract + Pricing

extension OptionContract {

    // MARK: Volatility

    /// Annualised historical volatility estimated from EODPrice history.
    /// Uses log-return standard deviation × √252.
    /// Prefers `adjClose`, falls back to `close`.
    func historicalVolatility(from prices: [EODPrice], lookback: Int = 30) -> Double? {
        let closes = prices
            .sorted { $0.priceDate < $1.priceDate }
            .suffix(lookback + 1)
            .map { $0.adjClose ?? $0.close }

        guard closes.count >= 2 else { return nil }

        let logReturns = zip(closes, closes.dropFirst()).map { log($1 / $0) }
        let mean = logReturns.reduce(0, +) / Double(logReturns.count)
        let variance = logReturns.map { pow($0 - mean, 2) }.reduce(0, +) / Double(logReturns.count - 1)
        return sqrt(variance * 252)
    }

    /// Annualised EWMA volatility using the RiskMetrics model.
    ///
    /// The variance is updated recursively: σ²_t = λ·σ²_{t-1} + (1-λ)·r²_t
    /// Seeded with the first squared log-return; all available price history is used
    /// (more data improves seed stability; the exponential decay naturally down-weights old returns).
    ///
    /// - Parameters:
    ///   - prices: EODPrice history for the underlying — at least 2 records required.
    ///   - lambda: Decay factor (default 0.94, the RiskMetrics daily-equity standard).
    ///             Higher λ = slower decay = more weight on older returns.
    /// - Returns: Annualised volatility estimate, or `nil` when fewer than 2 prices are supplied.
    func ewmaVolatility(from prices: [EODPrice], lambda: Double = 0.94) -> Double? {
        let closes = prices
            .sorted { $0.priceDate < $1.priceDate }
            .map { $0.adjClose ?? $0.close }

        guard closes.count >= 2 else { return nil }

        let logReturns = zip(closes, closes.dropFirst()).map { log($1 / $0) }

        // Seed with the first squared return to avoid a zero-variance start
        var variance = logReturns[0] * logReturns[0]
        for i in 1..<logReturns.count {
            let r = logReturns[i]
            variance = lambda * variance + (1 - lambda) * r * r
        }

        return sqrt(variance * 252)
    }

    /// Resolves volatility using the chosen method.
    private func resolveVolatility(from prices: [EODPrice], method: VolatilityMethod) -> Double? {
        switch method {
        case .historical(let lookback):
            return historicalVolatility(from: prices, lookback: lookback)
        case .ewma(let lambda):
            return ewmaVolatility(from: prices, lambda: lambda)
        }
    }

    // MARK: Time to Expiry

    /// Years remaining until `expirationDate` from a given reference date.
    func timeToExpiry(from referenceDate: Date = Date()) -> Double {
        expirationDate.timeIntervalSince(referenceDate) / (365 * 24 * 3600)
    }

    // MARK: Black-Scholes

    /// Price this contract using Black-Scholes (European exercise only).
    /// - Parameters:
    ///   - currentPrice: Latest EODPrice for the underlying.
    ///   - priceHistory: Historical EODPrice records used to estimate volatility.
    ///   - riskFreeRate: Annualised risk-free rate (e.g. 0.05 = 5%).
    ///   - volatilityMethod: How to estimate volatility — `.historical(lookback:)` or `.ewma(lambda:)`.
    ///   - marketPrice: Optional observed market price — populates `impliedVolatility` when supplied.
    /// - Returns: `OptionPriceResult` or `nil` when inputs are invalid / insufficient history.
    func blackScholesPrice(
        currentPrice: EODPrice,
        priceHistory: [EODPrice],
        riskFreeRate: Double = 0.05,
        volatilityMethod: VolatilityMethod = .historical(lookback: 30),
        marketPrice: Double? = nil
    ) -> OptionPriceResult? {

        let S = currentPrice.adjClose ?? currentPrice.close
        let T = timeToExpiry()
        guard T > 0, let sigma = resolveVolatility(from: priceHistory, method: volatilityMethod) else { return nil }

        let (price, greeks) = _blackScholes(S: S, K: strikePrice, T: T, r: riskFreeRate, sigma: sigma)
        let iv = marketPrice.flatMap {
            _impliedVolatility(marketPrice: $0, S: S, K: strikePrice, T: T, r: riskFreeRate)
        }

        return OptionPriceResult(
            price: price,
            contractValue: price * contractMultiplier,
            greeks: greeks,
            impliedVolatility: iv,
            model: "Black-Scholes (European)",
            underlyingPrice: S,
            timeToExpiry: T,
            historicalVolatility: sigma
        )
    }

    // MARK: Binomial Tree (CRR)

    /// Price this contract using a Cox-Ross-Rubinstein binomial tree.
    /// Supports European and American exercise; Bermudan is treated as American.
    /// - Parameters:
    ///   - currentPrice: Latest EODPrice for the underlying.
    ///   - priceHistory: Historical EODPrice records used to estimate volatility.
    ///   - riskFreeRate: Annualised risk-free rate (e.g. 0.05 = 5%).
    ///   - volatilityMethod: How to estimate volatility — `.historical(lookback:)` or `.ewma(lambda:)`.
    ///   - steps: Number of binomial tree steps (higher = more accurate, slower).
    /// - Returns: `OptionPriceResult` or `nil` when inputs are invalid / insufficient history.
    func binomialPrice(
        currentPrice: EODPrice,
        priceHistory: [EODPrice],
        riskFreeRate: Double = 0.05,
        volatilityMethod: VolatilityMethod = .historical(lookback: 30),
        steps: Int = 200,
        impliedVolatility: Double? = nil
    ) -> OptionPriceResult? {

        let S = currentPrice.adjClose ?? currentPrice.close
        let T = timeToExpiry()
        guard T > 0, let histVol = resolveVolatility(from: priceHistory, method: volatilityMethod) else { return nil }

        let sigma = impliedVolatility ?? histVol   // ← prefer IV when available

        let (price, greeks) = _binomialCRR(S: S, K: K, T: T, r: riskFreeRate, sigma: sigma, steps: steps)

        let styleLabel: String
        switch exerciseStyle {
        case .american: styleLabel = "American"
        case .european: styleLabel = "European"
        case .bermudan: styleLabel = "Bermudan/American"
        }

        return OptionPriceResult(
            price: price,
            contractValue: price * contractMultiplier,
            greeks: greeks,
            impliedVolatility: impliedVolatility,
            model: "Binomial CRR (\(styleLabel), \(steps) steps)",
            underlyingPrice: S,
            timeToExpiry: T,
            historicalVolatility: sigma
        )
    }

    // MARK: Combined

    /// Convenience — returns Black-Scholes and Binomial results together.
    func price(
        currentPrice: EODPrice,
        priceHistory: [EODPrice],
        riskFreeRate: Double = 0.05,
        volatilityMethod: VolatilityMethod = .historical(lookback: 30),
        steps: Int = 200,
        marketPrice: Double? = nil
    ) -> (blackScholes: OptionPriceResult, binomial: OptionPriceResult)? {

        guard
            let bs  = blackScholesPrice(
                currentPrice: currentPrice, priceHistory: priceHistory,
                riskFreeRate: riskFreeRate, volatilityMethod: volatilityMethod,
                marketPrice: marketPrice),
            let bin = binomialPrice(
                currentPrice: currentPrice, priceHistory: priceHistory,
                riskFreeRate: riskFreeRate, volatilityMethod: volatilityMethod,
                steps: steps)
        else { return nil }

        return (bs, bin)
    }

    // MARK: - Private: Black-Scholes Core

    private func _blackScholes(
        S: Double, K: Double, T: Double, r: Double, sigma: Double
    ) -> (Double, Greeks) {

        guard T > 0, sigma > 0 else {
            return (_intrinsic(S: S, K: K), Greeks(delta: 0, gamma: 0, theta: 0, vega: 0, rho: 0))
        }

        let sqrtT = sqrt(T)
        let d1  = (log(S / K) + (r + 0.5 * sigma * sigma) * T) / (sigma * sqrtT)
        let d2  = d1 - sigma * sqrtT
        let df  = exp(-r * T)
        let nd1 = MathHelpers.normalPDF(d1)

        let price: Double
        let delta: Double
        let rho:   Double

        switch optionType {
        case .call:
            let Nd1 = MathHelpers.normalCDF(d1), Nd2 = MathHelpers.normalCDF(d2)
            price = S * Nd1 - K * df * Nd2
            delta = Nd1
            rho   = K * T * df * Nd2 / 100
        case .put:
            let Nnd1 = MathHelpers.normalCDF(-d1), Nnd2 = MathHelpers.normalCDF(-d2)
            price = K * df * Nnd2 - S * Nnd1
            delta = Nnd1 - 1
            rho   = -K * T * df * Nnd2 / 100
        }

        let gamma = nd1 / (S * sigma * sqrtT)
        let vega  = S * nd1 * sqrtT / 100

        let thetaCommon = -(S * nd1 * sigma) / (2 * sqrtT) - r * K * df
        let theta: Double
        switch optionType {
        case .call: theta = (thetaCommon + r * K * df * MathHelpers.normalCDF(d2))  / 365
        case .put:  theta = (thetaCommon + r * K * df * MathHelpers.normalCDF(-d2)) / 365
        }

        return (price, Greeks(delta: delta, gamma: gamma, theta: theta, vega: vega, rho: rho))
    }

    // MARK: - Private: Implied Volatility (Newton-Raphson)

    private func _impliedVolatility(
        marketPrice: Double, S: Double, K: Double, T: Double, r: Double,
        tolerance: Double = 1e-6, maxIterations: Int = 100
    ) -> Double? {
        var sigma = 0.20
        for _ in 0..<maxIterations {
            let (theo, greeks) = _blackScholes(S: S, K: K, T: T, r: r, sigma: sigma)
            let diff = theo - marketPrice
            guard abs(diff) > tolerance else { return sigma }
            let vegaRaw = greeks.vega * 100
            guard abs(vegaRaw) > 1e-10 else { return nil }
            sigma -= diff / vegaRaw
            if sigma <= 0 { sigma = 1e-4 }
        }
        return nil
    }

    // MARK: - Private: Binomial CRR Core

    private func _binomialCRR(
        S: Double, K: Double, T: Double, r: Double, sigma: Double, steps: Int
    ) -> (Double, Greeks) {

        guard T > 0, sigma > 0 else {
            return (_intrinsic(S: S, K: K), Greeks(delta: 0, gamma: 0, theta: 0, vega: 0, rho: 0))
        }

        let isAmerican = exerciseStyle != .european

        func treePrice(S: Double, K: Double, T: Double, r: Double, sigma: Double) -> Double {
            let dt = T / Double(steps)
            let u  = exp(sigma * sqrt(dt))
            let d  = 1.0 / u
            let df = exp(-r * dt)
            let p  = (exp(r * dt) - d) / (u - d)

            var values = (0...steps).map { j in
                _intrinsic(S: S * pow(u, Double(2 * j - steps)), K: K)
            }
            for i in stride(from: steps - 1, through: 0, by: -1) {
                for j in 0...i {
                    let cont = df * (p * values[j + 1] + (1 - p) * values[j])
                    values[j] = isAmerican
                        ? max(cont, _intrinsic(S: S * pow(u, Double(2 * j - i)), K: K))
                        : cont
                }
            }
            return values[0]
        }

        let price = treePrice(S: S, K: K, T: T, r: r, sigma: sigma)

        // Greeks via finite difference (bump-and-reprice)
        let dS   = S * 0.001
        let dSig = sigma * 0.001
        let dR   = 0.001
        let dT   = min(1.0 / 365.0, T * 0.5)

        let pUp   = treePrice(S: S + dS, K: K, T: T,      r: r,      sigma: sigma)
        let pDn   = treePrice(S: S - dS, K: K, T: T,      r: r,      sigma: sigma)
        let pSigU = treePrice(S: S,      K: K, T: T,      r: r,      sigma: sigma + dSig)
        let pSigD = treePrice(S: S,      K: K, T: T,      r: r,      sigma: sigma - dSig)
        let pRU   = treePrice(S: S,      K: K, T: T,      r: r + dR, sigma: sigma)
        let pRD   = treePrice(S: S,      K: K, T: T,      r: r - dR, sigma: sigma)
        let pT    = treePrice(S: S,      K: K, T: T - dT, r: r,      sigma: sigma)

        let greeks = Greeks(
            delta: (pUp - pDn) / (2 * dS),
            gamma: (pUp - 2 * price + pDn) / (dS * dS),
            theta: (pT - price) / dT,
            vega:  (pSigU - pSigD) / (2 * dSig) / 100,
            rho:   (pRU - pRD) / (2 * dR) / 100
        )

        return (price, greeks)
    }

    // MARK: - Private: Intrinsic Value

    private func _intrinsic(S: Double, K: Double) -> Double {
        switch optionType {
        case .call: return max(S - K, 0)
        case .put:  return max(K - S, 0)
        }
    }
}

// MARK: - Vapor Route Integration

extension OptionContract {

    /// Register pricing routes on the Vapor app.
    /// Call from configure.swift: `OptionContract.registerPricingRoutes(on: app)`
    ///
    /// POST /options/:optionID/price
    /// Body: PricingRequest (all fields optional with sensible defaults)
    static func registerPricingRoutes(on app: Application) {
        app.post("options", ":optionID", "price") { req async throws -> PricingResponse in
            let body = try req.content.decode(PricingRequest.self)

            guard let optionID = req.parameters.get("optionID", as: UUID.self) else {
                throw AppError.invalidRouteParameter("optionID")
            }
            guard let contract = try await OptionContract.find(optionID, on: req.db) else {
                throw AppError.contractNotFound
            }

            let history = try await EODPrice.query(on: req.db)
                .filter(\.$instrument.$id == contract.$underlying.id)
                .sort(\.$priceDate, .descending)
                .limit(body.lookback + 1)
                .all()

            guard let latest = history.first else {
                throw AppError.noUnderlyingPriceData
            }
            let volMethod: VolatilityMethod = body.ewmaLambda.map { .ewma(lambda: $0) }
                ?? .historical(lookback: body.lookback)

            guard let (bs, bin) = contract.price(
                currentPrice: latest,
                priceHistory: history,
                riskFreeRate: body.riskFreeRate,
                volatilityMethod: volMethod,
                steps: body.steps,
                marketPrice: body.marketPrice
            ) else {
                throw AppError.pricingFailed
            }

            return PricingResponse(blackScholes: bs, binomial: bin)
        }
    }
}

// MARK: - Request / Response DTOs

extension OptionContract {

    struct PricingRequest: Content {
        var riskFreeRate: Double = 0.05   // annualised, e.g. 0.05 = 5%
        var lookback: Int        = 30     // trading days for historical vol estimation
        var ewmaLambda: Double?           // when set, use EWMA vol with this decay factor (e.g. 0.94)
        var steps: Int           = 200    // binomial tree steps
        var marketPrice: Double?          // supply to get implied volatility
    }

    struct PricingResponse: Content {
        let blackScholes: OptionPriceResult
        let binomial: OptionPriceResult
    }
}
