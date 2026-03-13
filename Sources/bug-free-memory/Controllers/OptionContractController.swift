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
        struct Context: Encodable {
            var contracts: [OptionContract]
            var underlyings: [Instrument]
            var optionInstruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("option-contracts", context: Context(contracts: contracts, underlyings: underlyings, optionInstruments: optionInstruments, flash: flash, flashType: flashType))
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

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        struct TheoreticalPriceRow: Encodable {
            var model: String
            var underlyingPrice: Double
            var price: String
            var historicalVolatility: String
            var impliedVolatility: String?
            var delta: String?
            var gamma: String?
            var theta: String?
            var vega: String?
            var rho: String?
        }

        struct DateRow: Encodable {
            var priceDate: String
            var bid: Double?
            var ask: Double?
            var mid: Double?
            var last: Double?
            var settlementPrice: Double?
            var volume: Int?
            var openInterest: Int?
            var impliedVolatility: Double?
            var delta: Double?
            var gamma: Double?
            var theta: Double?
            var vega: Double?
            var underlyingPrice: Double?
            var source: String?
            var hasEOD: Bool
            var theoreticalPrices: [TheoreticalPriceRow]
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
                underlyingPrice: t.underlyingPrice,
                price: String(format: "%.2f", t.price),
                historicalVolatility: String(format: "%.5f", t.historicalVolatility),
                impliedVolatility: t.impliedVolatility.map { String(format: "%.5f", $0) },
                delta: t.delta.map { String(format: "%.5f", $0) },
                gamma: t.gamma.map { String(format: "%.5f", $0) },
                theta: t.theta.map { String(format: "%.5f", $0) },
                vega: t.vega.map { String(format: "%.5f", $0) },
                rho: t.rho.map { String(format: "%.5f", $0) }
            )
            theoreticalByDate[dateStr, default: []].append(row)
        }

        // Build merged rows: start with EOD prices, then add theoretical-only dates
        var dateRows: [DateRow] = prices.map { p in
            let dateStr = df.string(from: p.priceDate)
            return DateRow(
                priceDate: dateStr,
                bid: p.bid, ask: p.ask, mid: p.mid, last: p.last,
                settlementPrice: p.settlementPrice,
                volume: p.volume, openInterest: p.openInterest,
                impliedVolatility: p.impliedVolatility,
                delta: p.delta, gamma: p.gamma, theta: p.theta, vega: p.vega,
                underlyingPrice: p.underlyingPrice,
                source: p.source,
                hasEOD: true,
                theoreticalPrices: theoreticalByDate[dateStr] ?? []
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
