import Fluent
import Leaf
import Vapor
import ClerkVapor

struct InstrumentController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("instruments")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    private func requireAuth(_ req: Request) throws {
        guard req.clerkAuth.isAuthenticated else { throw Abort.redirect(to: "/dashboard") }
    }

    func index(req: Request) async throws -> View {
        try requireAuth(req)
        async let instruments = Instrument.query(on: req.db).sort(\.$ticker).all()
        async let exchanges   = Exchange.query(on: req.db).sort(\.$micCode).all()
        async let currencies  = Currency.query(on: req.db).sort(\.$name).all()
        let flash = req.session.data["flash"]; req.session.data["flash"] = nil
        let flashType = req.session.data["flashType"]; req.session.data["flashType"] = nil
        struct Context: Encodable {
            var instruments: [Instrument]
            var exchanges: [Exchange]
            var currencies: [Currency]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("instruments", context: Context(instruments: instruments, exchanges: exchanges, currencies: currencies, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try requireAuth(req)
        struct Input: Content {
            var instrument_type: String; var ticker: String; var name: String
            var exchange_id: UUID?; var currency_code: String; var is_active: String?
        }
        let input = try req.content.decode(Input.self)
        guard let type = InstrumentType(rawValue: input.instrument_type) else {
            return flash(req, "Invalid instrument type.", type: "error", to: "/instruments")
        }
        let instrument = Instrument(
            instrumentType: type, ticker: input.ticker.uppercased(), name: input.name,
            exchangeID: input.exchange_id, currencyCode: input.currency_code,
            isActive: input.is_active == "on"
        )
        try await instrument.save(on: req.db)
        return flash(req, "\(input.ticker.uppercased()) added successfully.", type: "success", to: "/instruments")
    }

    func update(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: UUID.self),
              let instrument = try await Instrument.find(id, on: req.db) else {
            return flash(req, "Instrument not found.", type: "error", to: "/instruments")
        }
        struct Input: Content { var name: String; var exchange_id: UUID?; var currency_code: String; var is_active: String? }
        let input = try req.content.decode(Input.self)
        instrument.name = input.name
        instrument.$exchange.id = input.exchange_id
        instrument.$currency.id = input.currency_code
        instrument.isActive = input.is_active == "on"
        try await instrument.save(on: req.db)
        return flash(req, "\(instrument.ticker) updated successfully.", type: "success", to: "/instruments")
    }

    func delete(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: UUID.self),
              let instrument = try await Instrument.find(id, on: req.db) else {
            return flash(req, "Instrument not found.", type: "error", to: "/instruments")
        }
        let ticker = instrument.ticker
        try await instrument.delete(on: req.db)
        return flash(req, "\(ticker) deleted.", type: "success", to: "/instruments")
    }

    private func flash(_ req: Request, _ msg: String, type: String, to path: String) -> Response {
        req.session.data["flash"] = msg; req.session.data["flashType"] = type
        return req.redirect(to: path)
    }
}
