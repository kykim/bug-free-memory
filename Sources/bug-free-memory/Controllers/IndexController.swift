import Fluent
import Foundation
import Leaf
import Vapor
import ClerkVapor

struct IndexController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("indexes")
        g.get(use: index); g.post(use: create)
        g.get(":id", use: show)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
        g.post(":id", "fetch-today", use: fetchToday)
        g.post(":id", "backfill", use: backfill)
    }

    // MARK: - List

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        async let indexes     = Index.query(on: req.db).all()
        async let instruments = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" = 'index'::instrument_type"))
            .sort(\.$ticker).all()
        let (flash, flashType) = req.popFlash()

        let instrumentByID = Dictionary(uniqueKeysWithValues: try await instruments.map { ($0.id!, $0) })

        struct IndexRow: Encodable {
            var id: String
            var ticker: String
            var indexFamily: String?
            var methodology: String?
            var rebalanceFreq: String?
        }
        let rows = try await indexes.map { idx in
            IndexRow(
                id: idx.id!.uuidString,
                ticker: instrumentByID[idx.id!]?.ticker ?? idx.id!.uuidString,
                indexFamily: idx.indexFamily,
                methodology: idx.methodology,
                rebalanceFreq: idx.rebalanceFreq
            )
        }

        struct Context: Encodable {
            var indexes: [IndexRow]
            var instruments: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("indexes", context: Context(indexes: rows, instruments: try await instruments, flash: flash, flashType: flashType))
    }

    // MARK: - Detail

    func show(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let instrument = try await Instrument.find(id, on: req.db),
              let idx = try await Index.find(id, on: req.db) else {
            throw Abort(.notFound)
        }

        let page = max(1, (req.query["page"] as Int?) ?? 1)
        let pageSize = 200
        let prices = try await EODPrice.query(on: req.db)
            .filter(\.$instrument.$id == id)
            .sort(\.$priceDate, .descending)
            .range((page - 1) * pageSize ..< page * pageSize)
            .all()

        let df = DateFormatter.utcYMD

        struct PriceRow: Encodable {
            var priceDate: String
            var open: Double?
            var high: Double?
            var low: Double?
            var close: Double
            var volume: Int?
            var source: String?
        }
        let priceRows = prices.map { p in
            PriceRow(priceDate: df.string(from: p.priceDate),
                     open: p.open, high: p.high, low: p.low,
                     close: p.close, volume: p.volume, source: p.source)
        }

        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var id: String
            var ticker: String
            var name: String
            var indexFamily: String?
            var methodology: String?
            var rebalanceFreq: String?
            var prices: [PriceRow]
            var page: Int
            var prevPage: Int
            var nextPage: Int
            var hasNextPage: Bool
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("index-detail", context: Context(
            id: id.uuidString,
            ticker: instrument.ticker,
            name: instrument.name,
            indexFamily: idx.indexFamily,
            methodology: idx.methodology,
            rebalanceFreq: idx.rebalanceFreq,
            prices: priceRows,
            page: page,
            prevPage: page - 1,
            nextPage: page + 1,
            hasNextPage: prices.count == pageSize,
            flash: flash,
            flashType: flashType
        ))
    }

    // MARK: - Fetch Today

    func fetchToday(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let instrument = try await Instrument.find(id, on: req.db) else {
            return req.flash("Index not found.", type: "error", to: "/indexes")
        }
        guard let schwab = req.application.schwab else {
            return req.flash("Schwab client not configured.", type: "error", to: "/indexes/\(id)")
        }
        do {
            try await schwab.refreshTokenIfNeeded(db: req.db)
            guard let quote = try await schwab.fetchIndexQuote(ticker: instrument.ticker),
                  let close = quote.closePrice else {
                return req.flash("No quote returned for \(instrument.ticker).", type: "error", to: "/indexes/\(id)")
            }
            let priceDate = Calendar.utc.startOfDay(for: Date())
            try await upsertEODPrice(
                on: req.db, instrumentID: id, priceDate: priceDate,
                open: quote.openPrice, high: quote.highPrice, low: quote.lowPrice,
                close: close, volume: quote.totalVolume
            )
        } catch {
            return req.flash("Fetch failed: \(error)", type: "error", to: "/indexes/\(id)")
        }
        return req.flash("Today's price fetched for \(instrument.ticker).", type: "success", to: "/indexes/\(id)")
    }

    // MARK: - Backfill

    func backfill(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let instrument = try await Instrument.find(id, on: req.db) else {
            return req.flash("Index not found.", type: "error", to: "/indexes")
        }
        guard let schwab = req.application.schwab else {
            return req.flash("Schwab client not configured.", type: "error", to: "/indexes/\(id)")
        }
        let count: Int
        do {
            try await schwab.refreshTokenIfNeeded(db: req.db)
            let history = try await schwab.fetchPriceHistory(ticker: instrument.ticker)
            var upserted = 0
            for candle in history.candles {
                let priceDate = Calendar.utc.startOfDay(for: candle.date)
                try await upsertEODPrice(
                    on: req.db, instrumentID: id, priceDate: priceDate,
                    open: candle.open, high: candle.high, low: candle.low,
                    close: candle.close, volume: candle.volume
                )
                upserted += 1
            }
            count = upserted
        } catch {
            return req.flash("Backfill failed: \(error)", type: "error", to: "/indexes/\(id)")
        }
        return req.flash("Backfilled \(count) prices for \(instrument.ticker).", type: "success", to: "/indexes/\(id)")
    }

    // MARK: - CRUD

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        let input = try req.content.decode(CreateIndexDTO.self)
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
        let input = try req.content.decode(UpdateIndexDTO.self)
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

// MARK: - Helpers

private func upsertEODPrice(
    on db: any Database,
    instrumentID: UUID,
    priceDate: Date,
    open: Double?,
    high: Double?,
    low: Double?,
    close: Double,
    volume: Int?
) async throws {
    if let existing = try await EODPrice.query(on: db)
        .filter(\.$instrument.$id == instrumentID)
        .filter(\.$priceDate == priceDate)
        .first() {
        existing.open   = open
        existing.high   = high
        existing.low    = low
        existing.close  = close
        existing.volume = volume
        existing.source = "schwab"
        try await existing.save(on: db)
    } else {
        try await EODPrice(
            instrumentID: instrumentID, priceDate: priceDate,
            open: open, high: high, low: low,
            close: close, volume: volume, source: "schwab"
        ).create(on: db)
    }
}

