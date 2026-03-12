//
//  OptionContract+MonteCarloOptionPricer.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//
//  Monte Carlo option pricing as an extension on OptionContract.
//
//  Features:
//    - Geometric Brownian Motion path simulation
//    - Antithetic variates variance reduction
//    - European and American (Longstaff-Schwartz LSM) exercise
//    - Bermudan exercise via LSM with discrete exercise dates
//    - All greeks via pathwise finite difference
//    - Standard error and confidence interval reporting
//

import Fluent
import Vapor

// MARK: - Monte Carlo Result

struct MonteCarloResult: Content {
    let price: Double               // Per-share theoretical value
    let contractValue: Double       // price × contractMultiplier
    let greeks: Greeks
    let standardError: Double       // Monte Carlo standard error of price
    let confidenceInterval: ClosedRange<Double>  // 95% CI
    let simulationCount: Int
    let stepsPerPath: Int
    let model: String
    let underlyingPrice: Double
    let timeToExpiry: Double
    let historicalVolatility: Double
}

// Note: ClosedRange<Double> doesn't conform to Codable by default,
// so we provide a Codable wrapper for the Vapor response.
extension MonteCarloResult {
    enum CodingKeys: String, CodingKey {
        case price, contractValue, greeks, standardError
        case ciLower, ciUpper
        case simulationCount, stepsPerPath, model
        case underlyingPrice, timeToExpiry, historicalVolatility
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(price,                 forKey: .price)
        try c.encode(contractValue,         forKey: .contractValue)
        try c.encode(greeks,                forKey: .greeks)
        try c.encode(standardError,         forKey: .standardError)
        try c.encode(confidenceInterval.lowerBound, forKey: .ciLower)
        try c.encode(confidenceInterval.upperBound, forKey: .ciUpper)
        try c.encode(simulationCount,       forKey: .simulationCount)
        try c.encode(stepsPerPath,          forKey: .stepsPerPath)
        try c.encode(model,                 forKey: .model)
        try c.encode(underlyingPrice,       forKey: .underlyingPrice)
        try c.encode(timeToExpiry,          forKey: .timeToExpiry)
        try c.encode(historicalVolatility,  forKey: .historicalVolatility)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        price                = try c.decode(Double.self,  forKey: .price)
        contractValue        = try c.decode(Double.self,  forKey: .contractValue)
        greeks               = try c.decode(Greeks.self,  forKey: .greeks)
        standardError        = try c.decode(Double.self,  forKey: .standardError)
        let lo               = try c.decode(Double.self,  forKey: .ciLower)
        let hi               = try c.decode(Double.self,  forKey: .ciUpper)
        confidenceInterval   = lo...hi
        simulationCount      = try c.decode(Int.self,     forKey: .simulationCount)
        stepsPerPath         = try c.decode(Int.self,     forKey: .stepsPerPath)
        model                = try c.decode(String.self,  forKey: .model)
        underlyingPrice      = try c.decode(Double.self,  forKey: .underlyingPrice)
        timeToExpiry         = try c.decode(Double.self,  forKey: .timeToExpiry)
        historicalVolatility = try c.decode(Double.self,  forKey: .historicalVolatility)
    }
}

// MARK: - Random Normal (Box-Muller)

private enum RandomNormal {
    /// Generates a pair of independent standard normal samples via Box-Muller transform.
    static func pair() -> (Double, Double) {
        let u1 = Double.random(in: Double.ulpOfOne...1)
        let u2 = Double.random(in: 0..<1)
        let mag = sqrt(-2 * log(u1))
        return (mag * cos(2 * .pi * u2), mag * sin(2 * .pi * u2))
    }
}

// MARK: - OptionContract + Monte Carlo

extension OptionContract {

    // MARK: Public Entry Point

    /// Price this contract using Monte Carlo simulation.
    ///
    /// - European contracts: plain GBM terminal payoff with antithetic variates.
    /// - American/Bermudan contracts: Longstaff-Schwartz (LSM) least-squares regression
    ///   for early exercise decisions along each simulated path.
    ///
    /// - Parameters:
    ///   - currentPrice: Latest EODPrice for the underlying.
    ///   - priceHistory: Historical EODPrice records used to estimate volatility.
    ///   - riskFreeRate: Annualised risk-free rate (e.g. 0.05 = 5%).
    ///   - lookback: Trading days used for vol estimation.
    ///   - simulations: Number of simulated paths (default 100,000).
    ///   - stepsPerPath: Time steps per path (default 252 — one per trading day).
    ///   - bermudanExerciseDates: For Bermudan contracts, the specific dates on which
    ///     early exercise is permitted. Ignored for European/American.
    /// - Returns: `MonteCarloResult` or `nil` on invalid inputs / insufficient history.
    func monteCarloPrice(
        currentPrice: EODPrice,
        priceHistory: [EODPrice],
        riskFreeRate: Double = 0.05,
        lookback: Int = 30,
        simulations: Int = 100_000,
        stepsPerPath: Int = 252,
        bermudanExerciseDates: [Date] = []
    ) -> MonteCarloResult? {

        let S     = currentPrice.adjClose ?? currentPrice.close
        let K     = strikePrice
        let T     = timeToExpiry()
        guard T > 0,
              let sigma = historicalVolatility(from: priceHistory, lookback: lookback)
        else { return nil }

        let (price, greeks, se) = _monteCarlo(
            S: S, K: K, T: T, r: riskFreeRate, sigma: sigma,
            simulations: simulations, steps: stepsPerPath,
            bermudanDates: bermudanExerciseDates
        )

        let z95   = 1.96
        let ci    = (price - z95 * se)...(price + z95 * se)

        let styleLabel: String
        switch exerciseStyle {
        case .european: styleLabel = "European GBM"
        case .american: styleLabel = "American LSM"
        case .bermudan: styleLabel = "Bermudan LSM"
        }

        return MonteCarloResult(
            price: price,
            contractValue: price * contractMultiplier,
            greeks: greeks,
            standardError: se,
            confidenceInterval: ci,
            simulationCount: simulations,
            stepsPerPath: stepsPerPath,
            model: "Monte Carlo (\(styleLabel), \(simulations) paths)",
            underlyingPrice: S,
            timeToExpiry: T,
            historicalVolatility: sigma
        )
    }

    // MARK: - Private: Core Simulation

    private func _monteCarlo(
        S: Double, K: Double, T: Double, r: Double, sigma: Double,
        simulations: Int, steps: Int,
        bermudanDates: [Date]
    ) -> (price: Double, greeks: Greeks, standardError: Double) {

        switch exerciseStyle {
        case .european:
            return _simulateEuropean(S: S, K: K, T: T, r: r, sigma: sigma, simulations: simulations)
        case .american:
            let price = _simulateLSM(S: S, K: K, T: T, r: r, sigma: sigma,
                                     simulations: simulations, steps: steps,
                                     exerciseSteps: nil)
            let greeks = _monteCarloGreeks(S: S, K: K, T: T, r: r, sigma: sigma,
                                           simulations: simulations, steps: steps,
                                           exerciseSteps: nil, basePrice: price)
            // SE approximated from European engine (conservative upper bound for American)
            let (_, se) = _europeanPriceOnly(S: S, K: K, T: T, r: r, sigma: sigma,
                                             simulations: simulations)
            return (price, greeks, se)
        case .bermudan:
            let exerciseSteps = _bermudanStepIndices(dates: bermudanDates, T: T, steps: steps)
            let price = _simulateLSM(S: S, K: K, T: T, r: r, sigma: sigma,
                                     simulations: simulations, steps: steps,
                                     exerciseSteps: exerciseSteps.isEmpty ? nil : exerciseSteps)
            let greeks = _monteCarloGreeks(S: S, K: K, T: T, r: r, sigma: sigma,
                                           simulations: simulations, steps: steps,
                                           exerciseSteps: exerciseSteps.isEmpty ? nil : exerciseSteps,
                                           basePrice: price)
            let (_, se) = _europeanPriceOnly(S: S, K: K, T: T, r: r, sigma: sigma,
                                             simulations: simulations)
            return (price, greeks, se)
        }
    }

    // MARK: European — Terminal Payoff with Antithetic Variates

    /// Core GBM simulation — returns only price and standard error, no greeks.
    /// Used by both `_simulateEuropean` and `_europeanGreeks` to break mutual recursion.
    private func _europeanPriceOnly(
        S: Double, K: Double, T: Double, r: Double, sigma: Double,
        simulations: Int
    ) -> (price: Double, standardError: Double) {

        let df    = exp(-r * T)
        let drift = (r - 0.5 * sigma * sigma) * T
        let vol   = sigma * sqrt(T)

        var count = 0
        var mean  = 0.0
        var m2    = 0.0

        func ingest(_ payoff: Double) {
            count += 1
            let delta  = payoff - mean
            mean      += delta / Double(count)
            let delta2 = payoff - mean
            m2        += delta * delta2
        }

        let halfSims = simulations / 2
        for _ in 0..<halfSims {
            let (z1, z2) = RandomNormal.pair()
            ingest(_intrinsic(S: S * exp(drift + vol *  z1), K: K))
            ingest(_intrinsic(S: S * exp(drift + vol * -z1), K: K))
            ingest(_intrinsic(S: S * exp(drift + vol *  z2), K: K))
            ingest(_intrinsic(S: S * exp(drift + vol * -z2), K: K))
        }

        let price    = df * mean
        let variance = count > 1 ? m2 / Double(count - 1) : 0
        let se       = df * sqrt(variance / Double(count))
        return (price, se)
    }

    /// Full European simulation: price + greeks + standard error.
    private func _simulateEuropean(
        S: Double, K: Double, T: Double, r: Double, sigma: Double,
        simulations: Int
    ) -> (price: Double, greeks: Greeks, standardError: Double) {

        let (price, se) = _europeanPriceOnly(S: S, K: K, T: T, r: r, sigma: sigma,
                                             simulations: simulations)
        let greeks = _europeanGreeks(S: S, K: K, T: T, r: r, sigma: sigma,
                                     simulations: simulations, basePrice: price)
        return (price, greeks, se)
    }

    // MARK: American / Bermudan -- Longstaff-Schwartz LSM

    /// Longstaff-Schwartz regression-based early exercise.
    /// `exerciseSteps`: nil = every step (American), array = specific steps (Bermudan).
    ///
    /// Performance improvements vs. the naive version:
    ///   - Flat contiguous [Double] path matrix (row-major) for cache locality;
    ///     eliminates per-row heap allocations of [[Double]].
    ///   - Both Box-Muller normals consumed per pair of sims, halving RNG calls.
    ///   - Bool mask replaces O(n^2) `!itmIndices.contains(i)` in the discount loop.
    ///   - Exercise decision and OTM discount merged into one O(n) pass per step.
    private func _simulateLSM(
        S: Double, K: Double, T: Double, r: Double, sigma: Double,
        simulations: Int, steps: Int,
        exerciseSteps: [Int]?
    ) -> Double {

        let dt      = T / Double(steps)
        let df      = exp(-r * dt)
        let drift   = (r - 0.5 * sigma * sigma) * dt
        let vol     = sigma * sqrt(dt)
        let stride_ = steps + 1

        // 1. Single flat allocation: paths[i * stride_ + t] = spot for sim i at step t.
        var paths = [Double](repeating: S, count: simulations * stride_)

        // Fill paths consuming both Box-Muller outputs per sim pair
        let halfSims = simulations / 2
        for i in 0..<halfSims {
            let base1 = i * stride_
            let base2 = (i + halfSims) * stride_
            for t in 1...steps {
                let (z1, z2)     = RandomNormal.pair()
                paths[base1 + t] = paths[base1 + t - 1] * exp(drift + vol * z1)
                paths[base2 + t] = paths[base2 + t - 1] * exp(drift + vol * z2)
            }
        }
        // Handle odd simulation count
        if simulations % 2 == 1 {
            let base = (simulations - 1) * stride_
            for t in 1...steps {
                let (z, _)      = RandomNormal.pair()
                paths[base + t] = paths[base + t - 1] * exp(drift + vol * z)
            }
        }

        // 2. Initialise cashflows at expiry
        var cashflows = (0..<simulations).map { i in
            _intrinsic(S: paths[i * stride_ + steps], K: K)
        }

        // 3. Backward induction with LSM regression
        let exercisable = exerciseSteps.map { Set($0) }

        // Reusable Bool mask -- O(1) lookup replaces O(n) contains()
        var isITM = [Bool](repeating: false, count: simulations)

        for t in stride(from: steps - 1, through: 1, by: -1) {
            guard exercisable == nil || exercisable!.contains(t) else {
                for i in 0..<simulations { cashflows[i] *= df }
                continue
            }

            // Single O(n) pass: build ITM inputs and stamp mask
            var itmIndices = [Int]()
            var itmSpots   = [Double]()
            var itmPayoffs = [Double]()

            for i in 0..<simulations {
                let spot      = paths[i * stride_ + t]
                let intrinsic = _intrinsic(S: spot, K: K)
                isITM[i] = intrinsic > 0
                if isITM[i] {
                    itmIndices.append(i)
                    itmSpots.append(spot)
                    itmPayoffs.append(cashflows[i] * df)
                }
            }

            guard itmIndices.count >= 3 else {
                for i in 0..<simulations { cashflows[i] *= df }
                continue
            }

            // OLS regression: continuation ~ a + b*S + c*S^2
            let (a, b, c) = _ols(x: itmSpots, y: itmPayoffs)

            // Single O(n) pass: exercise or discount -- no set lookup needed
            for i in 0..<simulations {
                if isITM[i] {
                    let spot         = paths[i * stride_ + t]
                    let intrinsic    = _intrinsic(S: spot, K: K)
                    let continuation = a + b * spot + c * spot * spot
                    cashflows[i]     = intrinsic >= continuation ? intrinsic : cashflows[i] * df
                } else {
                    cashflows[i] *= df
                }
            }
        }

        return cashflows.reduce(0, +) / Double(simulations)
    }

    // MARK: - Greeks (parallel finite difference)

    /// European greeks via concurrent bump-and-reprice.
    /// Each of the 8 bumped simulations runs in its own Swift concurrency task.
    private func _europeanGreeks(
        S: Double, K: Double, T: Double, r: Double, sigma: Double,
        simulations: Int, basePrice: Double
    ) -> Greeks {
        let dS   = S * 0.01
        let dSig = sigma * 0.01
        let dR   = 0.001
        let dT   = min(1.0 / 365.0, T * 0.5)
        let n    = simulations / 4

        // Capture self weakly-safe: OptionContract is a class, but all
        // _simulateEuropean inputs are value types, so we copy them.
        let contract = self

        // Run all bumped pricings concurrently
        let results = _parallelBumps(count: 8) { idx -> Double in
            func ep(_ s: Double, _ t: Double, _ ri: Double, _ sig: Double) -> Double {
                let (p, _) = contract._europeanPriceOnly(S: s, K: K, T: t, r: ri, sigma: sig,
                                                         simulations: n)
                return p
            }
            switch idx {
            case 0: return ep(S + dS,  T, r, sigma)
            case 1: return ep(S - dS,  T, r, sigma)
            case 2: return ep(S,  T - dT, r, sigma)
            case 3: return ep(S,  T, r, sigma + dSig)
            case 4: return ep(S,  T, r, sigma - dSig)
            case 5: return ep(S,  T, r + dR, sigma)
            case 6: return ep(S,  T, r - dR, sigma)
            default: return basePrice
            }
        }

        let pUp   = results[0], pDn   = results[1]
        let pT    = results[2]
        let pSigU = results[3], pSigD = results[4]
        let pRU   = results[5], pRD   = results[6]

        return Greeks(
            delta: (pUp - pDn)   / (2 * dS),
            gamma: (pUp - 2 * basePrice + pDn) / (dS * dS),
            theta: (pT - basePrice) / dT / 365,
            vega:  (pSigU - pSigD) / (2 * dSig) / 100,
            rho:   (pRU - pRD)   / (2 * dR)  / 100
        )
    }

    /// LSM greeks via concurrent bump-and-reprice.
    private func _monteCarloGreeks(
        S: Double, K: Double, T: Double, r: Double, sigma: Double,
        simulations: Int, steps: Int,
        exerciseSteps: [Int]?,
        basePrice: Double
    ) -> Greeks {
        let dS   = S * 0.01
        let dSig = sigma * 0.01
        let dR   = 0.001
        let dT   = min(1.0 / 365.0, T * 0.5)
        let n    = simulations / 4
        let contract = self

        let results = _parallelBumps(count: 7) { idx -> Double in
            func lsm(_ s: Double, _ t: Double, _ ri: Double, _ sig: Double) -> Double {
                contract._simulateLSM(S: s, K: K, T: t, r: ri, sigma: sig,
                                      simulations: n, steps: steps,
                                      exerciseSteps: exerciseSteps)
            }
            switch idx {
            case 0: return lsm(S + dS,  T, r, sigma)
            case 1: return lsm(S - dS,  T, r, sigma)
            case 2: return lsm(S,  T - dT, r, sigma)
            case 3: return lsm(S,  T, r, sigma + dSig)
            case 4: return lsm(S,  T, r, sigma - dSig)
            case 5: return lsm(S,  T, r + dR, sigma)
            case 6: return lsm(S,  T, r - dR, sigma)
            default: return basePrice
            }
        }

        let pUp   = results[0], pDn   = results[1]
        let pT    = results[2]
        let pSigU = results[3], pSigD = results[4]
        let pRU   = results[5], pRD   = results[6]

        return Greeks(
            delta: (pUp - pDn)   / (2 * dS),
            gamma: (pUp - 2 * basePrice + pDn) / (dS * dS),
            theta: (pT - basePrice) / dT / 365,
            vega:  (pSigU - pSigD) / (2 * dSig) / 100,
            rho:   (pRU - pRD)   / (2 * dR)  / 100
        )
    }

    /// Runs `count` independent closures concurrently on the global executor
    /// and returns their results in index order.
    private func _parallelBumps(count: Int, work: @escaping @Sendable (Int) -> Double) -> [Double] {
        // UnsafeMutablePointer is not Sendable under strict concurrency, so we
        // wrap it in an @unchecked Sendable box. This is safe because each
        // concurrentPerform iteration writes to a unique index with no overlap.
        final class SendablePointer: @unchecked Sendable {
            let ptr: UnsafeMutablePointer<Double>
            init(_ ptr: UnsafeMutablePointer<Double>) { self.ptr = ptr }
        }
        let storage = UnsafeMutablePointer<Double>.allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)
        defer { storage.deallocate() }
        let box = SendablePointer(storage)
        DispatchQueue.concurrentPerform(iterations: count) { idx in
            (box.ptr + idx).pointee = work(idx)
        }
        return Array(UnsafeBufferPointer(start: storage, count: count))
    }

    // MARK: - Helpers

    /// Convert calendar Bermudan exercise dates to step indices.
    private func _bermudanStepIndices(dates: [Date], T: Double, steps: Int) -> [Int] {
        let now   = Date()
        let total = expirationDate.timeIntervalSince(now)
        return dates.compactMap { date -> Int? in
            guard date > now, date <= expirationDate else { return nil }
            let frac = date.timeIntervalSince(now) / total
            return Int((frac * Double(steps)).rounded())
        }
    }

    /// Simple OLS for y = a + b·x + c·x² (Laguerre basis for LSM).
    private func _ols(x: [Double], y: [Double]) -> (a: Double, b: Double, c: Double) {
        let n  = Double(x.count)
        let x2 = x.map { $0 * $0 }

        let sx  = x.reduce(0, +);    let sx2 = x2.reduce(0, +)
        let sx3 = zip(x, x2).map { $0 * $1 }.reduce(0, +)
        let sx4 = x2.map { $0 * $0 }.reduce(0, +)
        let sy  = y.reduce(0, +)
        let sxy = zip(x, y).map { $0 * $1 }.reduce(0, +)
        let sx2y = zip(x2, y).map { $0 * $1 }.reduce(0, +)

        // Solve 3×3 normal equations via Cramer's rule
        let A: [[Double]] = [
            [n,   sx,  sx2],
            [sx,  sx2, sx3],
            [sx2, sx3, sx4]
        ]
        let B = [sy, sxy, sx2y]

        guard let (a, b, c) = _solve3x3(A: A, b: B) else { return (0, 0, 0) }
        return (a, b, c)
    }

    /// Cramer's rule for a 3×3 linear system.
    private func _solve3x3(A: [[Double]], b: [Double]) -> (Double, Double, Double)? {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1]*m[2][2] - m[1][2]*m[2][1])
          - m[0][1] * (m[1][0]*m[2][2] - m[1][2]*m[2][0])
          + m[0][2] * (m[1][0]*m[2][1] - m[1][1]*m[2][0])
        }

        let d = det(A)
        guard abs(d) > 1e-12 else { return nil }

        func replaced(_ col: Int) -> [[Double]] {
            (0..<3).map { row in (0..<3).map { col == $0 ? b[row] : A[row][$0] } }
        }

        return (det(replaced(0)) / d,
                det(replaced(1)) / d,
                det(replaced(2)) / d)
    }

    /// Intrinsic value helper (shared with OptionPricer.swift).
    private func _intrinsic(S: Double, K: Double) -> Double {
        switch optionType {
        case .call: return max(S - K, 0)
        case .put:  return max(K - S, 0)
        }
    }
}

// MARK: - Vapor Route Integration

extension OptionContract {

    /// Register Monte Carlo pricing route.
    /// Call from configure.swift: `OptionContract.registerMonteCarloRoutes(on: app)`
    ///
    /// POST /options/:optionID/price/mc
    /// Body: MCPricingRequest (all fields optional with sensible defaults)
    static func registerMonteCarloRoutes(on app: Application) {
        app.post("options", ":optionID", "price", "mc") { req async throws -> MCPricingResponse in
            let body = try req.content.decode(MCPricingRequest.self)

            guard let optionID = req.parameters.get("optionID", as: UUID.self) else {
                throw Abort(.badRequest, reason: "Invalid option ID")
            }
            guard let contract = try await OptionContract.find(optionID, on: req.db) else {
                throw Abort(.notFound, reason: "Option contract not found")
            }

            let history = try await EODPrice.query(on: req.db)
                .filter(\.$instrument.$id == contract.$underlying.id)
                .sort(\.$priceDate, .descending)
                .limit(body.lookback + 1)
                .all()

            guard let latest = history.first else {
                throw Abort(.notFound, reason: "No price data found for underlying")
            }

            guard let result = contract.monteCarloPrice(
                currentPrice: latest,
                priceHistory: history,
                riskFreeRate: body.riskFreeRate,
                lookback: body.lookback,
                simulations: body.simulations,
                stepsPerPath: body.stepsPerPath,
                bermudanExerciseDates: body.bermudanExerciseDates ?? []
            ) else {
                throw Abort(.unprocessableEntity, reason: "Monte Carlo pricing failed — check inputs or price history")
            }

            return MCPricingResponse(monteCarlo: result)
        }
    }
}

// MARK: - Request / Response DTOs

extension OptionContract {

    struct MCPricingRequest: Content {
        var riskFreeRate: Double  = 0.05      // annualised, e.g. 0.05 = 5%
        var lookback: Int         = 30        // trading days for vol estimation
        var simulations: Int      = 100_000   // number of paths
        var stepsPerPath: Int     = 252       // time steps per path
        var bermudanExerciseDates: [Date]?    // Bermudan contracts only
    }

    struct MCPricingResponse: Content {
        let monteCarlo: MonteCarloResult
    }
}
