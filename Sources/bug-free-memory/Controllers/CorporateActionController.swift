import Fluent
import Leaf
import Vapor
import ClerkVapor

struct CorporateActionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("corporate-actions")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        async let actions     = CorporateAction.query(on: req.db).with(\.$instrument)
            .sort(\.$exDate, .descending).all()
        async let instruments = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" = 'equity'::instrument_type"))
            .sort(\.$ticker).all()
        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var actions: [CorporateAction]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("corporate-actions", context: Context(actions: actions, instruments: instruments, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        if let r = try req.validateContent(CreateCorporateActionDTO.self, redirectTo: "/corporate-actions") { return r }
        let input = try req.content.decode(CreateCorporateActionDTO.self)
        let exDate: Date
        do { exDate = try input.parsedExDate() } catch let error as AbortError {
            return req.flash(error.reason, type: "error", to: "/corporate-actions")
        }
        let action = CorporateAction(
            instrumentID: input.instrument_id,
            actionType: input.parsedActionType,
            exDate: exDate,
            recordDate: try input.parsedRecordDate(),
            payDate: try input.parsedPayDate(),
            ratio: input.ratio,
            notes: input.notes.ifNotEmpty
        )
        try await action.save(on: req.db)
        return req.flash("Corporate action created.", type: "success", to: "/corporate-actions")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let action = try await CorporateAction.find(id, on: req.db) else {
            return req.flash("Corporate action not found.", type: "error", to: "/corporate-actions")
        }
        if let r = try req.validateContent(UpdateCorporateActionDTO.self, redirectTo: "/corporate-actions") { return r }
        let input = try req.content.decode(UpdateCorporateActionDTO.self)
        let exDate: Date
        do { exDate = try input.parsedExDate() } catch let error as AbortError {
            return req.flash(error.reason, type: "error", to: "/corporate-actions")
        }
        action.exDate     = exDate
        action.recordDate = try input.parsedRecordDate()
        action.payDate    = try input.parsedPayDate()
        action.ratio      = input.ratio
        action.notes      = input.notes.ifNotEmpty
        try await action.save(on: req.db)
        return req.flash("Corporate action updated.", type: "success", to: "/corporate-actions")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let action = try await CorporateAction.find(id, on: req.db) else {
            return req.flash("Corporate action not found.", type: "error", to: "/corporate-actions")
        }
        try await action.delete(on: req.db)
        return req.flash("Corporate action deleted.", type: "success", to: "/corporate-actions")
    }
}
