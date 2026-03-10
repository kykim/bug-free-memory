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

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        let exchanges = try await Exchange.query(on: req.db).sort(\.$name).all()
        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var exchanges: [Exchange]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("exchanges", context: Context(exchanges: exchanges, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        struct Input: Content { var mic_code: String; var name: String; var country_code: String; var timezone: String }
        let input = try req.content.decode(Input.self)
        let exchange = Exchange(micCode: input.mic_code.uppercased(), name: input.name,
                                countryCode: input.country_code.uppercased(), timezone: input.timezone)
        try await exchange.save(on: req.db)
        return req.flash("\(input.mic_code.uppercased()) added successfully.", type: "success", to: "/exchanges")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let exchange = try await Exchange.find(id, on: req.db) else {
            return req.flash("Exchange not found.", type: "error", to: "/exchanges")
        }
        struct Input: Content { var name: String; var country_code: String; var timezone: String }
        let input = try req.content.decode(Input.self)
        exchange.name = input.name; exchange.countryCode = input.country_code.uppercased(); exchange.timezone = input.timezone
        try await exchange.save(on: req.db)
        return req.flash("\(exchange.micCode) updated successfully.", type: "success", to: "/exchanges")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let exchange = try await Exchange.find(id, on: req.db) else {
            return req.flash("Exchange not found.", type: "error", to: "/exchanges")
        }
        let mic = exchange.micCode
        try await exchange.delete(on: req.db)
        return req.flash("\(mic) deleted.", type: "success", to: "/exchanges")
    }
}
