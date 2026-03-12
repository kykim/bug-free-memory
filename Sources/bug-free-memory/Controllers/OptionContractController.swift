import Fluent
import Foundation
import Leaf
import Temporal
import Vapor
import ClerkVapor

struct OptionContractController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("option-contracts")
        g.get(use: index); g.post(use: create)
        g.get(":id", use: show)
        g.post(":id", "calculate-price", use: calculatePrice)
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

        struct PriceRow: Encodable {
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
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        let priceRows = prices.map { p in
            PriceRow(
                priceDate: df.string(from: p.priceDate),
                bid: p.bid, ask: p.ask, mid: p.mid, last: p.last,
                settlementPrice: p.settlementPrice,
                volume: p.volume, openInterest: p.openInterest,
                impliedVolatility: p.impliedVolatility,
                delta: p.delta, gamma: p.gamma, theta: p.theta, vega: p.vega,
                underlyingPrice: p.underlyingPrice,
                source: p.source
            )
        }

        // Load saved theoretical prices
        struct TheoreticalPriceRow: Encodable {
            var model: String
            var priceDate: String
            var underlyingPrice: Double
            var price: Double
            var historicalVolatility: Double
            var impliedVolatility: Double?
            var delta: Double?
            var gamma: Double?
            var theta: Double?
            var vega: Double?
            var rho: Double?
        }

        let theoreticalPrices = try await TheoreticalOptionEODPrice.query(on: req.db)
            .filter(\.$instrument.$id == id)
            .sort(\.$priceDate, .descending)
            .all()

        let theoreticalPriceRows = theoreticalPrices.map { t in
            TheoreticalPriceRow(
                model: t.modelDetail ?? t.model.rawValue,
                priceDate: df.string(from: t.priceDate),
                underlyingPrice: t.underlyingPrice,
                price: t.price,
                historicalVolatility: t.historicalVolatility,
                impliedVolatility: t.impliedVolatility,
                delta: t.delta,
                gamma: t.gamma,
                theta: t.theta,
                vega: t.vega,
                rho: t.rho
            )
        }

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
            var theoreticalPrices: [TheoreticalPriceRow]
            var prices: [PriceRow]
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
            theoreticalPrices: theoreticalPriceRows,
            prices: priceRows,
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
        _ = try await req.application.temporal.startWorkflow(
            type: PriceOptionContractWorkflow.self,
            options: .init(
                id: "price-option-\(id)-\(UUID())",
                taskQueue: "option-pricing"
            ),
            input: PriceOptionContractInput(contractID: id)
        )
        return req.flash("Pricing calculation started.", type: "success", to: "/option-contracts/\(id)")
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        struct Input: Content {
            var instrument_id: UUID; var underlying_id: UUID
            var option_type: String; var exercise_style: String
            var strike_price: Double; var expiration_date: String
            var contract_multiplier: Double?; var settlement_type: String?; var osi_symbol: String?
        }
        let input = try req.content.decode(Input.self)
        guard let optType = OptionType(rawValue: input.option_type),
              let exStyle = ExerciseStyle(rawValue: input.exercise_style) else {
            return req.flash("Invalid option type or exercise style.", type: "error", to: "/option-contracts")
        }
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        guard let expDate = fmt.date(from: input.expiration_date) else {
            return req.flash("Invalid expiration date format.", type: "error", to: "/option-contracts")
        }
        let contract = OptionContract(
            instrumentID: input.instrument_id, underlyingID: input.underlying_id,
            optionType: optType, exerciseStyle: exStyle,
            strikePrice: input.strike_price, expirationDate: expDate,
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
        struct Input: Content {
            var strike_price: Double; var expiration_date: String
            var contract_multiplier: Double; var settlement_type: String; var osi_symbol: String?
        }
        let input = try req.content.decode(Input.self)
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        guard let expDate = fmt.date(from: input.expiration_date) else {
            return req.flash("Invalid expiration date format.", type: "error", to: "/option-contracts")
        }
        contract.strikePrice = input.strike_price; contract.expirationDate = expDate
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
