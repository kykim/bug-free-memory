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

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        let currencies = try await Currency.query(on: req.db).sort(\.$name).all()
        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var currencies: [Currency]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("currencies", context: Context(currencies: currencies, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        if let r = try req.validateContent(CreateCurrencyDTO.self, redirectTo: "/currencies") { return r }
        let input = try req.content.decode(CreateCurrencyDTO.self)
        let code = input.currency_code.uppercased()
        if try await Currency.find(code, on: req.db) != nil {
            return req.flash("\(code) already exists.", type: "error", to: "/currencies")
        }
        try await Currency(currencyCode: code, name: input.name).save(on: req.db)
        return req.flash("\(code) — \(input.name) added successfully.", type: "success", to: "/currencies")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let code = req.parameters.get("code") else { throw AppError.missingRouteParameter("code") }
        if let r = try req.validateContent(UpdateCurrencyDTO.self, redirectTo: "/currencies") { return r }
        let input = try req.content.decode(UpdateCurrencyDTO.self)
        guard let currency = try await Currency.find(code, on: req.db) else {
            return req.flash("\(code) not found.", type: "error", to: "/currencies")
        }
        currency.name = input.name
        try await currency.save(on: req.db)
        return req.flash("\(code) updated successfully.", type: "success", to: "/currencies")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let code = req.parameters.get("code") else { throw AppError.missingRouteParameter("code") }
        guard let currency = try await Currency.find(code, on: req.db) else {
            return req.flash("\(code) not found.", type: "error", to: "/currencies")
        }
        try await currency.delete(on: req.db)
        return req.flash("\(code) deleted.", type: "success", to: "/currencies")
    }
}
