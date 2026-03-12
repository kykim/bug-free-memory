import Fluent
import Foundation
import Leaf
import Vapor
import ClerkVapor

struct EquityController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("equities")
        g.get(use: index); g.post(use: create)
        g.get(":id", use: show)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
        g.post(":id", "backfill", use: backfill)
        g.post(":id", "fetch-today", use: fetchToday)
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

    func show(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let equity = try await Equity.query(on: req.db)
                .join(Instrument.self, on: \Instrument.$id == \Equity.$id)
                .filter(\.$id == id)
                .first() else {
            throw Abort(.notFound)
        }
        let instrument = try equity.joined(Instrument.self)

        let page = max(1, (req.query["page"] as Int?) ?? 1)
        let pageSize = 200
        let prices = try await EODPrice.query(on: req.db)
            .filter(\.$instrument.$id == id)
            .sort(\.$priceDate, .descending)
            .range((page - 1) * pageSize ..< page * pageSize)
            .all()

        struct PriceRow: Encodable {
            var priceDate: String
            var open: Double?
            var high: Double?
            var low: Double?
            var close: Double
            var adjClose: Double?
            var volume: Int?
            var vwap: Double?
            var source: String?
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        let priceRows = prices.map { p in
            PriceRow(
                priceDate: df.string(from: p.priceDate),
                open: p.open, high: p.high, low: p.low,
                close: p.close, adjClose: p.adjClose,
                volume: p.volume, vwap: p.vwap, source: p.source
            )
        }

        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var id: String
            var ticker: String
            var name: String
            var isin: String?
            var cusip: String?
            var figi: String?
            var sector: String?
            var industry: String?
            var sharesOutstanding: Int?
            var prices: [PriceRow]
            var page: Int
            var prevPage: Int
            var nextPage: Int
            var hasNextPage: Bool
            var flash: String?
            var flashType: String?
        }

        return try await req.clerkView("equity-detail", context: Context(
            id: id.uuidString,
            ticker: instrument.ticker,
            name: instrument.name,
            isin: equity.isin,
            cusip: equity.cusip,
            figi: equity.figi,
            sector: equity.sector,
            industry: equity.industry,
            sharesOutstanding: equity.sharesOutstanding,
            prices: priceRows,
            page: page,
            prevPage: page - 1,
            nextPage: page + 1,
            hasNextPage: prices.count == pageSize,
            flash: flash,
            flashType: flashType
        ))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        let input = try req.content.decode(CreateEquityDTO.self)
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
        let input = try req.content.decode(UpdateEquityDTO.self)
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

    func backfill(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let equity = try await Equity.query(on: req.db)
                .join(Instrument.self, on: \Instrument.$id == \Equity.$id)
                .filter(\.$id == id)
                .first() else {
            return req.flash("Equity not found.", type: "error", to: "/equities")
        }
        let ticker = try equity.joined(Instrument.self).ticker
        let startDate = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
        try await req.eodPriceService.backfill(equityID: id, ticker: ticker, from: startDate)
        return req.flash("Backfill started for \(ticker).", type: "success", to: "/equities/\(id.uuidString)")
    }

    func fetchToday(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let equity = try await Equity.query(on: req.db)
                .join(Instrument.self, on: \Instrument.$id == \Equity.$id)
                .filter(\.$id == id)
                .first() else {
            return req.flash("Equity not found.", type: "error", to: "/equities")
        }
        let ticker = try equity.joined(Instrument.self).ticker
        try await req.eodPriceService.fetchToday(equityID: id, ticker: ticker)
        return req.flash("Today's EOD price fetch started for \(ticker).", type: "success", to: "/equities/\(id.uuidString)")
    }
}
