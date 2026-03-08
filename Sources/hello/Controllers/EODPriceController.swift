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

    private func requireAuth(_ req: Request) throws {
        guard req.clerkAuth.isAuthenticated else { throw Abort.redirect(to: "/dashboard") }
    }

    func index(req: Request) async throws -> View {
        try requireAuth(req)
        async let prices      = EODPrice.query(on: req.db).with(\.$instrument)
            .sort(\.$priceDate, .descending).limit(200).all()
        async let instruments = Instrument.query(on: req.db).sort(\.$ticker).all()
        let flash = req.session.data["flash"]; req.session.data["flash"] = nil
        let flashType = req.session.data["flashType"]; req.session.data["flashType"] = nil
        struct Context: Encodable {
            var prices: [EODPrice]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("eod-prices", context: Context(prices: prices, instruments: instruments, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try requireAuth(req)
        struct Input: Content {
            var instrument_id: Int; var price_date: String
            var open: Double?; var high: Double?; var low: Double?; var close: Double
            var adj_close: Double?; var volume: Int?; var vwap: Double?; var source: String?
        }
        let input = try req.content.decode(Input.self)
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        guard let date = fmt.date(from: input.price_date) else {
            return flash(req, "Invalid date format.", type: "error", to: "/eod-prices")
        }
        let price = EODPrice(
            instrumentID: input.instrument_id, priceDate: date,
            open: input.open, high: input.high, low: input.low, close: input.close,
            adjClose: input.adj_close, volume: input.volume, vwap: input.vwap,
            source: input.source?.isEmpty == false ? input.source : nil
        )
        try await price.save(on: req.db)
        return flash(req, "EOD price record created.", type: "success", to: "/eod-prices")
    }

    func update(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: Int.self),
              let price = try await EODPrice.find(id, on: req.db) else {
            return flash(req, "Price record not found.", type: "error", to: "/eod-prices")
        }
        struct Input: Content {
            var open: Double?; var high: Double?; var low: Double?; var close: Double
            var adj_close: Double?; var volume: Int?; var vwap: Double?; var source: String?
        }
        let input = try req.content.decode(Input.self)
        price.open = input.open; price.high = input.high; price.low = input.low
        price.close = input.close; price.adjClose = input.adj_close
        price.volume = input.volume; price.vwap = input.vwap
        price.source = input.source?.isEmpty == false ? input.source : nil
        try await price.save(on: req.db)
        return flash(req, "EOD price record updated.", type: "success", to: "/eod-prices")
    }

    func delete(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: Int.self),
              let price = try await EODPrice.find(id, on: req.db) else {
            return flash(req, "Price record not found.", type: "error", to: "/eod-prices")
        }
        try await price.delete(on: req.db)
        return flash(req, "EOD price record deleted.", type: "success", to: "/eod-prices")
    }

    private func flash(_ req: Request, _ msg: String, type: String, to path: String) -> Response {
        req.session.data["flash"] = msg; req.session.data["flashType"] = type
        return req.redirect(to: path)
    }
}
