import Fluent
import Leaf
import Vapor
import ClerkVapor

struct IndexController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("indexes")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    private func requireAuth(_ req: Request) throws {
        guard req.clerkAuth.isAuthenticated else { throw Abort.redirect(to: "/dashboard") }
    }

    func index(req: Request) async throws -> View {
        try requireAuth(req)
        async let indexes     = Index.query(on: req.db).with(\.$instrument).all()
        async let instruments = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" = 'index'::instrument_type"))
            .sort(\.$ticker).all()
        let flash = req.session.data["flash"]; req.session.data["flash"] = nil
        let flashType = req.session.data["flashType"]; req.session.data["flashType"] = nil
        struct Context: Encodable {
            var indexes: [Index]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("indexes", context: Context(indexes: indexes, instruments: instruments, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try requireAuth(req)
        struct Input: Content { var instrument_id: Int; var index_family: String?; var methodology: String?; var rebalance_freq: String? }
        let input = try req.content.decode(Input.self)
        guard try await Index.find(input.instrument_id, on: req.db) == nil else {
            return flash(req, "Index record already exists for that instrument.", type: "error", to: "/indexes")
        }
        let idx = Index(
            instrumentID:  input.instrument_id,
            indexFamily:   input.index_family?.isEmpty   == false ? input.index_family   : nil,
            methodology:   input.methodology?.isEmpty    == false ? input.methodology    : nil,
            rebalanceFreq: input.rebalance_freq?.isEmpty == false ? input.rebalance_freq : nil
        )
        try await idx.save(on: req.db)
        return flash(req, "Index record created.", type: "success", to: "/indexes")
    }

    func update(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: Int.self),
              let idx = try await Index.find(id, on: req.db) else {
            return flash(req, "Index not found.", type: "error", to: "/indexes")
        }
        struct Input: Content { var index_family: String?; var methodology: String?; var rebalance_freq: String? }
        let input = try req.content.decode(Input.self)
        idx.indexFamily   = input.index_family?.isEmpty   == false ? input.index_family   : nil
        idx.methodology   = input.methodology?.isEmpty    == false ? input.methodology    : nil
        idx.rebalanceFreq = input.rebalance_freq?.isEmpty == false ? input.rebalance_freq : nil
        try await idx.save(on: req.db)
        return flash(req, "Index record updated.", type: "success", to: "/indexes")
    }

    func delete(req: Request) async throws -> Response {
        try requireAuth(req)
        guard let id = req.parameters.get("id", as: Int.self),
              let idx = try await Index.find(id, on: req.db) else {
            return flash(req, "Index not found.", type: "error", to: "/indexes")
        }
        try await idx.delete(on: req.db)
        return flash(req, "Index record deleted.", type: "success", to: "/indexes")
    }

    private func flash(_ req: Request, _ msg: String, type: String, to path: String) -> Response {
        req.session.data["flash"] = msg; req.session.data["flashType"] = type
        return req.redirect(to: path)
    }
}
