import Fluent
import Leaf
import Vapor
import ClerkVapor

struct CurrencyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("currencies")
        g.get(use: index); g.post(use: create)
        g.post(":code", "edit", use: update); g.post(":code", "delete", use: delete)
    }

    private func requireAuth(_ req: Request) throws {
        guard req.clerkAuth.isAuthenticated else { throw Abort.redirect(to: "/dashboard") }
    }

    func index(req: Request) async throws -> View {
        try requireAuth(req)
        let currencies = try await Currency.query(on: req.db).sort(\.$name).all()
        let flash = req.session.data["flash"]; req.session.data["flash"] = nil
        let flashType = req.session.data["flashType"]; req.session.data["flashType"] = nil
        struct Context: Encodable {
            var currencies: [Currency]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("currencies", context: Context(currencies: currencies, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try requireAuth(req)
        struct Input: Content { var currency_code: String; var name: String }
        let input = try req.content.decode(Input.self)
        guard input.currency_code.count == 3 else {
            return flash(req, "Currency code must be exactly 3 characters.", type: "error", to: "/currencies")
        }
        let code = input.currency_code.uppercased()
        if try await Currency.find(code, on: req.db) != nil {
            return flash(req, "\(code) already exists.", type: "error", to: "/currencies")
        }
        try await Currency(currencyCode: code, name: input.name).save(on: req.db)
        return flash(req, "\(code) — \(input.name) added successfully.", type: "success", to: "/currencies")
    }

    func update(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let code = req.parameters.get("code") else { throw Abort(.badRequest) }
        struct Input: Content { var name: String }
        let input = try req.content.decode(Input.self)
        guard let currency = try await Currency.find(code, on: req.db) else {
            return flash(req, "\(code) not found.", type: "error", to: "/currencies")
        }
        currency.name = input.name
        try await currency.save(on: req.db)
        return flash(req, "\(code) updated successfully.", type: "success", to: "/currencies")
    }

    func delete(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let code = req.parameters.get("code") else { throw Abort(.badRequest) }
        guard let currency = try await Currency.find(code, on: req.db) else {
            return flash(req, "\(code) not found.", type: "error", to: "/currencies")
        }
        try await currency.delete(on: req.db)
        return flash(req, "\(code) deleted.", type: "success", to: "/currencies")
    }

    private func flash(_ req: Request, _ msg: String, type: String, to path: String) -> Response {
        req.session.data["flash"] = msg; req.session.data["flashType"] = type
        return req.redirect(to: path)
    }
}
