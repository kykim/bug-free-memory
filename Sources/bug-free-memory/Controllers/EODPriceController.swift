import Fluent
import Leaf
import Vapor
import ClerkVapor

struct EODPriceController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("eod-prices")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        async let prices      = EODPrice.query(on: req.db).with(\.$instrument)
            .sort(\.$priceDate, .descending).limit(200).all()
        async let instruments = Instrument.query(on: req.db).sort(\.$ticker).all()
        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var prices: [EODPrice]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("eod-prices", context: Context(prices: prices, instruments: instruments, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        if let r = try req.validateContent(CreateEODPriceDTO.self, redirectTo: "/eod-prices") { return r }
        let input = try req.content.decode(CreateEODPriceDTO.self)
        let date: Date
        do { date = try input.parsedPriceDate() } catch let error as AbortError {
            return req.flash(error.reason, type: "error", to: "/eod-prices")
        }
        let price = EODPrice(
            instrumentID: input.instrument_id, priceDate: date,
            open: input.open, high: input.high, low: input.low, close: input.close,
            adjClose: input.adj_close, volume: input.volume, vwap: input.vwap,
            source: input.source.ifNotEmpty
        )
        try await price.save(on: req.db)
        return req.flash("EOD price record created.", type: "success", to: "/eod-prices")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let price = try await EODPrice.find(id, on: req.db) else {
            return req.flash("Price record not found.", type: "error", to: "/eod-prices")
        }
        if let r = try req.validateContent(UpdateEODPriceDTO.self, redirectTo: "/eod-prices") { return r }
        let input = try req.content.decode(UpdateEODPriceDTO.self)
        price.open = input.open; price.high = input.high; price.low = input.low
        price.close = input.close; price.adjClose = input.adj_close
        price.volume = input.volume; price.vwap = input.vwap
        price.source = input.source.ifNotEmpty
        try await price.save(on: req.db)
        return req.flash("EOD price record updated.", type: "success", to: "/eod-prices")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let price = try await EODPrice.find(id, on: req.db) else {
            return req.flash("Price record not found.", type: "error", to: "/eod-prices")
        }
        try await price.delete(on: req.db)
        return req.flash("EOD price record deleted.", type: "success", to: "/eod-prices")
    }
}
