import Fluent
import Leaf
import Vapor
import ClerkVapor

struct EquityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("equities")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()

        struct EquityRow: Encodable {
            var id: UUID?
            var ticker: String
            var isin: String?
            var cusip: String?
            var figi: String?
            var sector: String?
            var industry: String?
            var sharesOutstanding: Int?
        }

        async let equityResults = Equity.query(on: req.db)
            .join(Instrument.self, on: \Instrument.$id == \Equity.$id)
            .all()
        async let instruments = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" = 'equity'::instrument_type"))
            .sort(\.$ticker).all()

        let rows = try await equityResults.map { equity in
            let instrument = try equity.joined(Instrument.self)
            return EquityRow(
                id: equity.id,
                ticker: instrument.ticker,
                isin: equity.isin,
                cusip: equity.cusip,
                figi: equity.figi,
                sector: equity.sector,
                industry: equity.industry,
                sharesOutstanding: equity.sharesOutstanding
            )
        }

        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var equities: [EquityRow]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("equities", context: Context(equities: rows, instruments: try await instruments, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        struct Input: Content {
            var instrument_id: UUID; var isin: String?; var cusip: String?; var figi: String?
            var sector: String?; var industry: String?; var shares_outstanding: Int?
        }
        let input = try req.content.decode(Input.self)
        guard try await Equity.find(input.instrument_id, on: req.db) == nil else {
            return req.flash("Equity record already exists for that instrument.", type: "error", to: "/equities")
        }
        let equity = Equity(
            instrumentID: input.instrument_id,
            isin:     input.isin.ifNotEmpty,
            cusip:    input.cusip.ifNotEmpty,
            figi:     input.figi.ifNotEmpty,
            sector:   input.sector.ifNotEmpty,
            industry: input.industry.ifNotEmpty,
            sharesOutstanding: input.shares_outstanding
        )
        try await equity.save(on: req.db)
        return req.flash("Equity record created.", type: "success", to: "/equities")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let equity = try await Equity.find(id, on: req.db) else {
            return req.flash("Equity not found.", type: "error", to: "/equities")
        }
        struct Input: Content {
            var isin: String?; var cusip: String?; var figi: String?
            var sector: String?; var industry: String?; var shares_outstanding: Int?
        }
        let input = try req.content.decode(Input.self)
        equity.isin     = input.isin.ifNotEmpty
        equity.cusip    = input.cusip.ifNotEmpty
        equity.figi     = input.figi.ifNotEmpty
        equity.sector   = input.sector.ifNotEmpty
        equity.industry = input.industry.ifNotEmpty
        equity.sharesOutstanding = input.shares_outstanding
        try await equity.save(on: req.db)
        return req.flash("Equity record updated.", type: "success", to: "/equities")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let equity = try await Equity.find(id, on: req.db) else {
            return req.flash("Equity not found.", type: "error", to: "/equities")
        }
        try await equity.delete(on: req.db)
        return req.flash("Equity record deleted.", type: "success", to: "/equities")
    }
}
