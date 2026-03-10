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
        struct Input: Content {
            var instrument_id: UUID; var action_type: String; var ex_date: String
            var record_date: String?; var pay_date: String?; var ratio: Double?; var notes: String?
        }
        let input = try req.content.decode(Input.self)
        guard let actionType = CorporateActionType(rawValue: input.action_type) else {
            return req.flash("Invalid action type.", type: "error", to: "/corporate-actions")
        }
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        guard let exDate = fmt.date(from: input.ex_date) else {
            return req.flash("Invalid ex-date format.", type: "error", to: "/corporate-actions")
        }
        let action = CorporateAction(
            instrumentID: input.instrument_id, actionType: actionType, exDate: exDate,
            recordDate: input.record_date.flatMap { fmt.date(from: $0) },
            payDate:    input.pay_date.flatMap    { fmt.date(from: $0) },
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
        struct Input: Content {
            var ex_date: String; var record_date: String?; var pay_date: String?
            var ratio: Double?; var notes: String?
        }
        let input = try req.content.decode(Input.self)
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        guard let exDate = fmt.date(from: input.ex_date) else {
            return req.flash("Invalid ex-date format.", type: "error", to: "/corporate-actions")
        }
        action.exDate     = exDate
        action.recordDate = input.record_date.flatMap { fmt.date(from: $0) }
        action.payDate    = input.pay_date.flatMap    { fmt.date(from: $0) }
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
