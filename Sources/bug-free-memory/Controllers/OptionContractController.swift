import Fluent
import Foundation
import Leaf
import Vapor
import ClerkVapor

struct OptionContractController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("option-contracts")
        g.get(use: index); g.post(use: create)
        g.get(":id", use: show)
        g.post(":id", "calculate-price", use: calculatePrice)
        g.post(":id", "compute-mc-greeks", use: computeMCGreeks)
        g.post(":id", "fetch-schwab-price", use: fetchSchwabPrice)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        async let contracts   = OptionContract.query(on: req.db)
            .with(\.$underlying)
            .sort(\.$expirationDate).all()
        async let underlyings = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" IN ('equity'::instrument_type, 'index'::instrument_type)"))
            .sort(\.$ticker).all()
        async let optionInstruments = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" IN ('equity_option'::instrument_type, 'index_option'::instrument_type)"))
            .sort(\.$ticker).all()
        let (flash, flashType) = req.popFlash()
        let df = DateFormatter.utcYMD
        struct ContractRow: Encodable {
            var id: String
            var underlying: UnderlyingRow
            var optionType: String
            var exerciseStyle: String
            var strikePrice: Double
            var expirationDate: String
            var contractMultiplier: Double
            var settlementType: String
            var osiSymbol: String?
            struct UnderlyingRow: Encodable { var ticker: String }
        }
        let rows = try await contracts.map { c in
            ContractRow(
                id: c.id!.uuidString,
                underlying: .init(ticker: c.underlying.ticker),
                optionType: c.optionType.rawValue,
                exerciseStyle: c.exerciseStyle.rawValue,
                strikePrice: c.strikePrice,
                expirationDate: df.string(from: c.expirationDate),
                contractMultiplier: c.contractMultiplier,
                settlementType: c.settlementType,
                osiSymbol: c.osiSymbol
            )
        }
        struct Context: Encodable {
            var contracts: [ContractRow]
            var underlyings: [Instrument]
            var optionInstruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("option-contracts", context: Context(contracts: rows, underlyings: try await underlyings, optionInstruments: try await optionInstruments, flash: flash, flashType: flashType))
    }

    func show(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let contract = try await OptionContract.query(on: req.db)
                .with(\.$underlying)
                .filter(\.$id == id)
                .first() else {
            throw Abort(.notFound)
        }

        let underlying = contract.underlying
        let page = max(1, (req.query["page"] as Int?) ?? 1)
        let pageSize = 200
        let prices = try await OptionEODPrice.query(on: req.db)
            .filter(\.$instrument.$id == id)
            .sort(\.$priceDate, .descending)
            .range((page - 1) * pageSize ..< page * pageSize)
            .all()

        let df = DateFormatter.utcYMD

        struct TheoreticalPriceRow: Encodable {
            var model: String
            var underlyingPrice: String
            var price: String
            var historicalVolatility: String
            var impliedVolatility: String
            var delta: String
            var gamma: String
            var theta: String
            var vega: String
            var rho: String
        }

        struct DateRow: Encodable {
            var priceDate: String
            var bid: String
            var ask: String
            var mid: String
            var last: String
            var settlementPrice: String
            var volume: String
            var openInterest: String
            var impliedVolatility: String
            var delta: String
            var gamma: String
            var theta: String
            var vega: String
            var underlyingPrice: String
            var source: String
            var hasEOD: Bool
            var theoreticalPrices: [TheoreticalPriceRow]
            init(priceDate: String, hasEOD: Bool, theoreticalPrices: [TheoreticalPriceRow],
                 bid: Double? = nil, ask: Double? = nil, mid: Double? = nil, last: Double? = nil,
                 settlementPrice: Double? = nil, volume: Int? = nil, openInterest: Int? = nil,
                 impliedVolatility: Double? = nil, delta: Double? = nil, gamma: Double? = nil,
                 theta: Double? = nil, vega: Double? = nil, underlyingPrice: Double? = nil,
                 source: String? = nil) {
                self.priceDate        = priceDate
                self.hasEOD           = hasEOD
                self.theoreticalPrices = theoreticalPrices
                self.bid              = bid.map              { String(format: "%.2f", $0) } ?? ""
                self.ask              = ask.map              { String(format: "%.2f", $0) } ?? ""
                self.mid              = mid.map              { String(format: "%.2f", $0) } ?? ""
                self.last             = last.map             { String(format: "%.2f", $0) } ?? ""
                self.settlementPrice  = settlementPrice.map  { String(format: "%.2f", $0) } ?? ""
                self.volume           = volume.map           { String($0) }                 ?? ""
                self.openInterest     = openInterest.map     { String($0) }                 ?? ""
                self.impliedVolatility = impliedVolatility.map { String(format: "%.4f", $0) } ?? ""
                self.delta            = delta.map            { String(format: "%.5f", $0) } ?? ""
                self.gamma            = gamma.map            { String(format: "%.5f", $0) } ?? ""
                self.theta            = theta.map            { String(format: "%.5f", $0) } ?? ""
                self.vega             = vega.map             { String(format: "%.5f", $0) } ?? ""
                self.underlyingPrice  = underlyingPrice.map  { String(format: "%.2f", $0) } ?? ""
                self.source           = source ?? ""
            }
        }

        let theoreticalPrices = try await TheoreticalOptionEODPrice.query(on: req.db)
            .filter(\.$instrument.$id == id)
            .sort(\.$priceDate, .descending)
            .all()

        // Group theoretical prices by date string
        var theoreticalByDate: [String: [TheoreticalPriceRow]] = [:]
        for t in theoreticalPrices {
            let dateStr = df.string(from: t.priceDate)
            let row = TheoreticalPriceRow(
                model: t.modelDetail ?? t.model.rawValue,
                underlyingPrice: String(format: "%.2f", t.underlyingPrice),
                price: String(format: "%.2f", t.price),
                historicalVolatility: String(format: "%.5f", t.historicalVolatility),
                impliedVolatility: t.impliedVolatility.map { String(format: "%.5f", $0) } ?? "",
                delta: t.delta.map { String(format: "%.5f", $0) } ?? "",
                gamma: t.gamma.map { String(format: "%.5f", $0) } ?? "",
                theta: t.theta.map { String(format: "%.5f", $0) } ?? "",
                vega: t.vega.map { String(format: "%.5f", $0) } ?? "",
                rho: t.rho.map { String(format: "%.5f", $0) } ?? ""
            )
            theoreticalByDate[dateStr, default: []].append(row)
        }

        // Build merged rows: start with EOD prices, then add theoretical-only dates
        var dateRows: [DateRow] = prices.map { p in
            let dateStr = df.string(from: p.priceDate)
            return DateRow(
                priceDate: dateStr,
                hasEOD: true,
                theoreticalPrices: theoreticalByDate[dateStr] ?? [],
                bid: p.bid, ask: p.ask, mid: p.mid, last: p.last,
                settlementPrice: p.settlementPrice,
                volume: p.volume, openInterest: p.openInterest,
                impliedVolatility: p.impliedVolatility,
                delta: p.delta, gamma: p.gamma, theta: p.theta, vega: p.vega,
                underlyingPrice: p.underlyingPrice,
                source: p.source
            )
        }

        let eodDates = Set(dateRows.map(\.priceDate))
        let theoreticalOnlyDates = theoreticalByDate.keys
            .filter { !eodDates.contains($0) }
            .sorted(by: >)
        for dateStr in theoreticalOnlyDates {
            dateRows.append(DateRow(
                priceDate: dateStr,
                hasEOD: false,
                theoreticalPrices: theoreticalByDate[dateStr] ?? []
            ))
        }
        dateRows.sort { $0.priceDate > $1.priceDate }

        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var id: String
            var osiSymbol: String?
            var underlyingTicker: String
            var optionType: String
            var exerciseStyle: String
            var strikePrice: Double
            var expirationDate: String
            var contractMultiplier: Double
            var settlementType: String
            var dateRows: [DateRow]
            var page: Int
            var prevPage: Int
            var nextPage: Int
            var hasNextPage: Bool
            var flash: String?
            var flashType: String?
        }

        return try await req.clerkView("option-contract-detail", context: Context(
            id: id.uuidString,
            osiSymbol: contract.osiSymbol,
            underlyingTicker: underlying.ticker,
            optionType: contract.optionType.rawValue,
            exerciseStyle: contract.exerciseStyle.rawValue,
            strikePrice: contract.strikePrice,
            expirationDate: df.string(from: contract.expirationDate),
            contractMultiplier: contract.contractMultiplier,
            settlementType: contract.settlementType,
            dateRows: dateRows,
            page: page,
            prevPage: page - 1,
            nextPage: page + 1,
            hasNextPage: prices.count == pageSize,
            flash: flash,
            flashType: flashType
        ))
    }

    func calculatePrice(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self) else {
            return req.flash("Invalid contract ID.", type: "error", to: "/option-contracts")
        }
        guard try await OptionContract.find(id, on: req.db) != nil else {
            return req.flash("Contract not found.", type: "error", to: "/option-contracts")
        }
        try await req.optionPricingService.triggerPricing(for: id)
        return req.flash("Pricing calculation started.", type: "success", to: "/option-contracts/\(id)")
    }

    func computeMCGreeks(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self) else {
            return req.flash("Invalid contract ID.", type: "error", to: "/option-contracts")
        }
        guard try await OptionContract.find(id, on: req.db) != nil else {
            return req.flash("Contract not found.", type: "error", to: "/option-contracts")
        }
        try await req.optionPricingService.triggerGreeksComputation(for: id)
        return req.flash("Monte Carlo Greeks computation started.", type: "success", to: "/option-contracts/\(id)")
    }

    func fetchSchwabPrice(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let contract = try await OptionContract.find(id, on: req.db) else {
            return req.flash("Contract not found.", type: "error", to: "/option-contracts")
        }
        guard let osiSymbol = contract.osiSymbol, !osiSymbol.isEmpty else {
            return req.flash("Contract has no OSI symbol — cannot fetch from Schwab.", type: "error", to: "/option-contracts/\(id)")
        }
        guard let schwab = req.application.schwab else {
            return req.flash("Schwab client not configured.", type: "error", to: "/option-contracts/\(id)")
        }
        struct FetchForm: Content { var local_date: String? }
        let form = try req.content.decode(FetchForm.self)
        let priceDate: Date
        if let dateStr = form.local_date,
           let parsed = { let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"; df.timeZone = .current; return df }().date(from: dateStr) { // local TZ intentional — user-supplied date
            priceDate = parsed
        } else {
            priceDate = Calendar.current.startOfDay(for: Date())
        }
        do {
            try await schwab.refreshTokenIfNeeded(db: req.db)
            guard let quote = try await schwab.fetchOptionQuote(osiSymbol: osiSymbol) else {
                return req.flash("No quote returned for \(osiSymbol).", type: "error", to: "/option-contracts/\(id)")
            }
            let iv = quote.volatility.map { $0 / 100.0 }
            if let existing = try await OptionEODPrice.query(on: req.db)
                .filter(\.$instrument.$id == id)
                .filter(\.$priceDate == priceDate)
                .first() {
                existing.bid              = quote.bidPrice
                existing.ask              = quote.askPrice
                existing.last             = quote.lastPrice
                existing.settlementPrice  = quote.closePrice
                existing.volume           = quote.totalVolume
                existing.openInterest     = quote.openInterest
                existing.impliedVolatility = iv
                existing.delta            = quote.delta
                existing.gamma            = quote.gamma
                existing.theta            = quote.theta
                existing.vega             = quote.vega
                existing.rho              = quote.rho
                existing.underlyingPrice  = quote.underlyingPrice
                existing.source           = "schwab"
                try await existing.save(on: req.db)
            } else {
                try await OptionEODPrice(
                    instrumentID: id, priceDate: priceDate,
                    bid: quote.bidPrice, ask: quote.askPrice, last: quote.lastPrice,
                    settlementPrice: quote.closePrice, volume: quote.totalVolume,
                    openInterest: quote.openInterest, impliedVolatility: iv,
                    delta: quote.delta, gamma: quote.gamma, theta: quote.theta,
                    vega: quote.vega, rho: quote.rho, underlyingPrice: quote.underlyingPrice,
                    source: "schwab"
                ).create(on: req.db)
            }
        } catch {
            return req.flash("Fetch failed: \(error)", type: "error", to: "/option-contracts/\(id)")
        }
        return req.flash("Schwab price fetched for \(osiSymbol).", type: "success", to: "/option-contracts/\(id)")
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        if let r = try req.validateContent(CreateOptionContractDTO.self, redirectTo: "/option-contracts") { return r }
        let input = try req.content.decode(CreateOptionContractDTO.self)
        let expDate: Date
        do { expDate = try input.parsedExpirationDate() } catch let error as any AbortError {
            return req.flash(error.reason, type: "error", to: "/option-contracts")
        }
        let contract = OptionContract(
            instrumentID: input.instrument_id,
            underlyingID: input.underlying_id,
            optionType: input.parsedOptionType,
            exerciseStyle: input.parsedExerciseStyle,
            strikePrice: input.strike_price,
            expirationDate: expDate,
            contractMultiplier: input.contract_multiplier ?? 100,
            settlementType: input.settlement_type ?? "physical",
            osiSymbol: input.osi_symbol.ifNotEmpty
        )
        try await contract.save(on: req.db)
        return req.flash("Option contract created.", type: "success", to: "/option-contracts")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let contract = try await OptionContract.find(id, on: req.db) else {
            return req.flash("Contract not found.", type: "error", to: "/option-contracts")
        }
        if let r = try req.validateContent(UpdateOptionContractDTO.self, redirectTo: "/option-contracts/\(id)") { return r }
        let input = try req.content.decode(UpdateOptionContractDTO.self)
        let expDate: Date
        do { expDate = try input.parsedExpirationDate() } catch let error as any AbortError {
            return req.flash(error.reason, type: "error", to: "/option-contracts/\(id)")
        }
        contract.strikePrice = input.strike_price
        contract.expirationDate = expDate
        contract.contractMultiplier = input.contract_multiplier
        contract.settlementType = input.settlement_type
        contract.osiSymbol = input.osi_symbol.ifNotEmpty
        try await contract.save(on: req.db)
        return req.flash("Contract updated.", type: "success", to: "/option-contracts")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let contract = try await OptionContract.find(id, on: req.db) else {
            return req.flash("Contract not found.", type: "error", to: "/option-contracts")
        }
        try await contract.delete(on: req.db)
        return req.flash("Contract deleted.", type: "success", to: "/option-contracts")
    }
}
