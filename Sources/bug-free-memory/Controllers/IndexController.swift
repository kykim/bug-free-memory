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

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        async let indexes     = Index.query(on: req.db).with(\.$instrument).all()
        async let instruments = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" = 'index'::instrument_type"))
            .sort(\.$ticker).all()
        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var indexes: [Index]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("indexes", context: Context(indexes: indexes, instruments: instruments, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        struct Input: Content { var instrument_id: UUID; var index_family: String?; var methodology: String?; var rebalance_freq: String? }
        let input = try req.content.decode(Input.self)
        guard try await Index.find(input.instrument_id, on: req.db) == nil else {
            return req.flash("Index record already exists for that instrument.", type: "error", to: "/indexes")
        }
        let idx = Index(
            instrumentID:  input.instrument_id,
            indexFamily:   input.index_family.ifNotEmpty,
            methodology:   input.methodology.ifNotEmpty,
            rebalanceFreq: input.rebalance_freq.ifNotEmpty
        )
        try await idx.save(on: req.db)
        return req.flash("Index record created.", type: "success", to: "/indexes")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let idx = try await Index.find(id, on: req.db) else {
            return req.flash("Index not found.", type: "error", to: "/indexes")
        }
        struct Input: Content { var index_family: String?; var methodology: String?; var rebalance_freq: String? }
        let input = try req.content.decode(Input.self)
        idx.indexFamily   = input.index_family.ifNotEmpty
        idx.methodology   = input.methodology.ifNotEmpty
        idx.rebalanceFreq = input.rebalance_freq.ifNotEmpty
        try await idx.save(on: req.db)
        return req.flash("Index record updated.", type: "success", to: "/indexes")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let idx = try await Index.find(id, on: req.db) else {
            return req.flash("Index not found.", type: "error", to: "/indexes")
        }
        try await idx.delete(on: req.db)
        return req.flash("Index record deleted.", type: "success", to: "/indexes")
    }
}
