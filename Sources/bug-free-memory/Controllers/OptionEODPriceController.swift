import Fluent
import Leaf
import Vapor
import ClerkVapor

struct OptionEODPriceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("option-eod-prices")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        async let prices      = OptionEODPrice.query(on: req.db).with(\.$instrument)
            .sort(\.$priceDate, .descending).limit(200).all()
        async let instruments = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" IN ('equity_option'::instrument_type, 'index_option'::instrument_type)"))
            .sort(\.$ticker).all()
        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var prices: [OptionEODPrice]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("option-eod-prices", context: Context(prices: prices, instruments: instruments, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        if let r = try req.validateContent(CreateOptionEODPriceDTO.self, redirectTo: "/option-eod-prices") { return r }
        let input = try req.content.decode(CreateOptionEODPriceDTO.self)
        let date: Date
        do { date = try input.parsedPriceDate() } catch let error as AbortError {
            return req.flash(error.reason, type: "error", to: "/option-eod-prices")
        }
        let price = OptionEODPrice(
            instrumentID: input.instrument_id, priceDate: date,
            bid: input.bid, ask: input.ask, last: input.last,
            settlementPrice: input.settlement_price,
            volume: input.volume, openInterest: input.open_interest,
            impliedVolatility: input.implied_volatility,
            delta: input.delta, gamma: input.gamma, theta: input.theta,
            vega: input.vega, rho: input.rho,
            underlyingPrice: input.underlying_price,
            riskFreeRate: input.risk_free_rate, dividendYield: input.dividend_yield,
            source: input.source.ifNotEmpty
        )
        try await price.save(on: req.db)
        return req.flash("Option EOD price record created.", type: "success", to: "/option-eod-prices")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let price = try await OptionEODPrice.find(id, on: req.db) else {
            return req.flash("Price record not found.", type: "error", to: "/option-eod-prices")
        }
        if let r = try req.validateContent(UpdateOptionEODPriceDTO.self, redirectTo: "/option-eod-prices") { return r }
        let input = try req.content.decode(UpdateOptionEODPriceDTO.self)
        price.bid = input.bid; price.ask = input.ask; price.last = input.last
        price.settlementPrice = input.settlement_price
        price.volume = input.volume; price.openInterest = input.open_interest
        price.impliedVolatility = input.implied_volatility
        price.delta = input.delta; price.gamma = input.gamma
        price.theta = input.theta; price.vega = input.vega; price.rho = input.rho
        price.underlyingPrice = input.underlying_price
        price.riskFreeRate = input.risk_free_rate; price.dividendYield = input.dividend_yield
        price.source = input.source.ifNotEmpty
        try await price.save(on: req.db)
        return req.flash("Option EOD price record updated.", type: "success", to: "/option-eod-prices")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let price = try await OptionEODPrice.find(id, on: req.db) else {
            return req.flash("Price record not found.", type: "error", to: "/option-eod-prices")
        }
        try await price.delete(on: req.db)
        return req.flash("Option EOD price record deleted.", type: "success", to: "/option-eod-prices")
    }
}
