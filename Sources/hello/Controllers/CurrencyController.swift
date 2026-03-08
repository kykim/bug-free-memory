import Fluent
import Leaf
import Vapor
import ClerkVapor

struct CurrencyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let currencies = routes.grouped(ClerkMiddleware()).grouped("currencies")
        currencies.get(use: index)
        currencies.post(use: create)
        currencies.post(":code", "edit",   use: update)
        currencies.post(":code", "delete", use: delete)
    }

    // Throws a redirect to /dashboard if the request is not authenticated
    private func requireAuth(_ req: Request) throws {
        guard req.clerkAuth.isAuthenticated else {
            throw Abort.redirect(to: "/dashboard")
        }
    }

    // MARK: GET /currencies
    func index(req: Request) async throws -> View {
        try requireAuth(req)
        let currencies = try await Currency.query(on: req.db)
            .sort(\.$name)
            .all()

        struct Context: Encodable {
            var currencies: [Currency]
            var flash: String?
            var flashType: String?
        }

        let flash     = req.session.data["flash"]
        let flashType = req.session.data["flashType"]
        req.session.data["flash"]     = nil
        req.session.data["flashType"] = nil

        return try await req.view.render(
            "currencies",
            Context(currencies: currencies, flash: flash, flashType: flashType)
        )
    }

    // MARK: POST /currencies  — insert
    func create(req: Request) async throws -> Response {
        try requireAuth(req)
        struct Input: Content {
            var currency_code: String
            var name: String
        }

        let input = try req.content.decode(Input.self)

        guard input.currency_code.count == 3 else {
            return setFlashAndRedirect(req, "Currency code must be exactly 3 characters.", type: "error")
        }

        let code = input.currency_code.uppercased()

        // Check for duplicate
        if try await Currency.find(code, on: req.db) != nil {
            return setFlashAndRedirect(req, "\(code) already exists.", type: "error")
        }

        let currency = Currency(currencyCode: code, name: input.name)
        try await currency.save(on: req.db)

        return setFlashAndRedirect(req, "\(code) — \(input.name) added successfully.", type: "success")
    }

    // MARK: POST /currencies/:code/edit  — update
    func update(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let code = req.parameters.get("code") else {
            throw Abort(.badRequest, reason: "Missing currency code.")
        }

        struct Input: Content { var name: String }
        let input = try req.content.decode(Input.self)

        guard let currency = try await Currency.find(code, on: req.db) else {
            return setFlashAndRedirect(req, "\(code) not found.", type: "error")
        }

        currency.name = input.name
        try await currency.save(on: req.db)

        return setFlashAndRedirect(req, "\(code) updated successfully.", type: "success")
    }

    // MARK: POST /currencies/:code/delete  — delete
    func delete(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let code = req.parameters.get("code") else {
            throw Abort(.badRequest, reason: "Missing currency code.")
        }

        guard let currency = try await Currency.find(code, on: req.db) else {
            return setFlashAndRedirect(req, "\(code) not found.", type: "error")
        }

        try await currency.delete(on: req.db)

        return setFlashAndRedirect(req, "\(code) deleted.", type: "success")
    }

    // MARK: - Helpers

    private func setFlashAndRedirect(
        _ req: Request,
        _ message: String,
        type: String
    ) -> Response {
        req.session.data["flash"]     = message
        req.session.data["flashType"] = type
        return req.redirect(to: "/currencies")
    }
}
