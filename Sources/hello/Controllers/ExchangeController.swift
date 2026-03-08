import Fluent
import Leaf
import Vapor
import ClerkVapor

struct ExchangeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("exchanges")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    private func requireAuth(_ req: Request) throws {
        guard req.clerkAuth.isAuthenticated else { throw Abort.redirect(to: "/dashboard") }
    }

    func index(req: Request) async throws -> View {
        try requireAuth(req)
        let exchanges = try await Exchange.query(on: req.db).sort(\.$name).all()
        let flash = req.session.data["flash"]; req.session.data["flash"] = nil
        let flashType = req.session.data["flashType"]; req.session.data["flashType"] = nil
        struct Context: Encodable {
            var exchanges: [Exchange]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("exchanges", context: Context(exchanges: exchanges, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try requireAuth(req)
        struct Input: Content { var mic_code: String; var name: String; var country_code: String; var timezone: String }
        let input = try req.content.decode(Input.self)
        let exchange = Exchange(micCode: input.mic_code.uppercased(), name: input.name,
                                countryCode: input.country_code.uppercased(), timezone: input.timezone)
        try await exchange.save(on: req.db)
        return flash(req, "\(input.mic_code.uppercased()) added successfully.", type: "success", to: "/exchanges")
    }

    func update(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: Int.self),
              let exchange = try await Exchange.find(id, on: req.db) else {
            return flash(req, "Exchange not found.", type: "error", to: "/exchanges")
        }
        struct Input: Content { var name: String; var country_code: String; var timezone: String }
        let input = try req.content.decode(Input.self)
        exchange.name = input.name; exchange.countryCode = input.country_code.uppercased(); exchange.timezone = input.timezone
        try await exchange.save(on: req.db)
        return flash(req, "\(exchange.micCode) updated successfully.", type: "success", to: "/exchanges")
    }

    func delete(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: Int.self),
              let exchange = try await Exchange.find(id, on: req.db) else {
            return flash(req, "Exchange not found.", type: "error", to: "/exchanges")
        }
        let mic = exchange.micCode
        try await exchange.delete(on: req.db)
        return flash(req, "\(mic) deleted.", type: "success", to: "/exchanges")
    }

    private func flash(_ req: Request, _ msg: String, type: String, to path: String) -> Response {
        req.session.data["flash"] = msg; req.session.data["flashType"] = type
        return req.redirect(to: path)
    }
}
