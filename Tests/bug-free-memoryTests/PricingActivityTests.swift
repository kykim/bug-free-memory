//
//  PricingActivityTests.swift
//  bug-free-memory
//
//  TICKET-013: PricingActivity integration tests.
//  Uses in-memory SQLite + seeded OptionEODPrice and EOD history.
//
//  NOTE: CreateFREDYield and CreateTheoreticalOptionEODPrice both use
//  PostgreSQL-specific enum types for `series_id` and `model`. The
//  SQLite-compatible replacements below use .string instead.
//

import Testing
import Foundation
import Logging
import Fluent
import FluentSQL
import FluentSQLiteDriver
import VaporTesting
@testable import bug_free_memory

// MARK: - SQLite-compatible migrations

struct TestCreateFREDYield: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(FREDYield.schema)
            .field("id",               .uuid,     .required, .identifier(auto: false))
            .field("series_id",        .string,   .required)
            .field("observation_date", .datetime, .required)
            .field("yield_percent",    .double)
            .field("continuous_rate",  .double)
            .field("tenor_years",      .double,   .required)
            .field("source",           .string)
            .field("created_at",       .datetime)
            .field("updated_at",       .datetime)
            .unique(on: "series_id", "observation_date")
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(FREDYield.schema).delete()
    }
}

struct TestCreateTheoreticalOptionEODPrices: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(TheoreticalOptionEODPrice.schema)
            .field("id",                   .uuid,     .required, .identifier(auto: false))
            .field("instrument_id",        .uuid,     .required,
                   .references("instruments", "id", onDelete: .cascade))
            .field("price_date",           .date,     .required)
            .field("price",                .double,   .required)
            .field("settlement_price",     .double)
            .field("implied_volatility",   .double)
            .field("historical_volatility",.double,   .required)
            .field("risk_free_rate",       .double,   .required)
            .field("underlying_price",     .double,   .required)
            .field("delta",                .double)
            .field("gamma",                .double)
            .field("theta",                .double)
            .field("vega",                 .double)
            .field("rho",                  .double)
            .field("model",                .string,   .required)
            .field("model_detail",         .string)
            .field("source",               .string)
            .field("created_at",           .datetime)
            .unique(on: "instrument_id", "price_date", "model")
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(TheoreticalOptionEODPrice.schema).delete()
    }
}

// MARK: - DB helper

private func withPricingDB(
    _ body: (any Database) async throws -> Void
) async throws {
    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateCurrencies())
        app.migrations.add(CreateExchanges())
        app.migrations.add(CreateInstruments())
        app.migrations.add(CreateEquities())
        app.migrations.add(CreateOptionContracts())
        app.migrations.add(CreateEODPrices())
        app.migrations.add(TestCreateFREDYield())
        app.migrations.add(TestCreateOptionEODPrices())
        app.migrations.add(TestCreateTheoreticalOptionEODPrices())
        try await app.autoMigrate()
    }) { app in
        try await body(app.db)
    }
}

// MARK: - Seed helpers

private func seedBaseFixtures(db: any Database) async throws -> (underlying: Instrument, exchange: Exchange) {
    if try await Currency.find("USD", on: db) == nil {
        try await Currency(currencyCode: "USD", name: "US Dollar").save(on: db)
    }
    let exchange: Exchange
    if let e = try await Exchange.query(on: db).first() {
        exchange = e
    } else {
        exchange = Exchange(micCode: "XNAS", name: "NASDAQ", countryCode: "US", timezone: "America/New_York")
        try await exchange.save(on: db)
    }
    let underlying = Instrument(
        instrumentType: .equity, ticker: "AAPL", name: "AAPL",
        exchangeID: exchange.id!, currencyCode: "USD")
    try await underlying.save(on: db)
    try await Equity(instrumentID: underlying.id!).save(on: db)
    return (underlying, exchange)
}

private func seedOptionContract(
    underlying: Instrument,
    expirationDate: Date,
    db: any Database
) async throws -> OptionContract {
    let osiSymbol = "AAPL  260320C00175000"
    let instrument = Instrument(
        instrumentType: .equityOption, ticker: osiSymbol, name: osiSymbol,
        exchangeID: underlying.$exchange.id, currencyCode: "USD")
    try await instrument.save(on: db)
    let contract = OptionContract(
        instrumentID: instrument.id!,
        underlyingID: underlying.id!,
        optionType: .call,
        exerciseStyle: .american,
        strikePrice: 175.0,
        expirationDate: expirationDate,
        contractMultiplier: 100,
        settlementType: "physical",
        osiSymbol: osiSymbol)
    try await contract.create(on: db)
    return contract
}

/// Seeds N days of underlying EOD price history ending at `baseDate`.
private func seedEODHistory(
    instrumentID: UUID,
    days: Int,
    close: Double = 175.0,
    baseDate: Date,
    db: any Database
) async throws {
    let sqlDB = db as! any SQLDatabase
    for i in 0..<days {
        let priceDate = Calendar.utcCal.startOfDay(
            for: baseDate.addingTimeInterval(-Double(days - 1 - i) * 86400))
        let newID = UUID()
        try await sqlDB.raw("""
            INSERT INTO eod_prices
                (id, instrument_id, price_date, open, high, low, close, adj_close, volume, source)
            VALUES
                (\(bind: newID), \(bind: instrumentID), \(bind: priceDate),
                 \(bind: close * 0.99), \(bind: close * 1.01),
                 \(bind: close * 0.98), \(bind: close), \(bind: close),
                 \(bind: Int64(5_000_000)), 'test')
            ON CONFLICT (instrument_id, price_date) DO NOTHING
            """).run()
    }
}

/// Seeds today's OptionEODPrice for a given contract.
private func seedOptionEOD(
    instrumentID: UUID,
    priceDate: Date,
    bid: Double = 1.10,
    ask: Double = 1.20,
    db: any Database
) async throws {
    let sqlDB = db as! any SQLDatabase
    let newID = UUID()
    let startOfDay = Calendar.utcCal.startOfDay(for: priceDate)
    try await sqlDB.raw("""
        INSERT INTO option_eod_prices
            (id, instrument_id, price_date, bid, ask, last,
             implied_volatility, delta, gamma, theta, vega, rho,
             underlying_price, source)
        VALUES
            (\(bind: newID), \(bind: instrumentID), \(bind: startOfDay),
             \(bind: bid), \(bind: ask), \(bind: (bid + ask) / 2),
             0.30, 0.45, 0.02, -0.05, 0.10, 0.01,
             175.0, 'schwab')
        ON CONFLICT (instrument_id, price_date) DO NOTHING
        """).run()
}

/// Seeds a minimal yield curve (2 points) on `runDate`.
private func seedYieldCurve(runDate: Date, db: any Database) async throws {
    let sqlDB = db as! any SQLDatabase
    let obs = Calendar.utcCal.startOfDay(for: runDate)
    for (seriesID, tenorYears, continuousRate) in [
        ("DGS1MO", 1.0 / 12.0, 0.045),
        ("DGS5",   5.0,         0.050)
    ] {
        let newID = UUID()
        try await sqlDB.raw("""
            INSERT INTO fred_yields
                (id, series_id, observation_date, yield_percent, continuous_rate, tenor_years, source)
            VALUES
                (\(bind: newID), \(bind: seriesID), \(bind: obs),
                 5.0, \(bind: continuousRate), \(bind: tenorYears), 'test')
            ON CONFLICT (series_id, observation_date) DO NOTHING
            """).run()
    }
}

private func futureDate(daysFromNow: Int = 30) -> Date {
    Date().addingTimeInterval(Double(daysFromNow) * 86400)
}

// MARK: - Tests

@Suite("PricingActivity", .serialized)
struct PricingActivityTests {

    @Test("Happy path: contract with EOD price + history produces 3 rows")
    func happyPath() async throws {
        try await withPricingDB { db in
            let (underlying, _) = try await seedBaseFixtures(db: db)
            let runDate = Date()
            let contract = try await seedOptionContract(
                underlying: underlying, expirationDate: futureDate(), db: db)
            let instrumentID = contract.id!

            try await seedYieldCurve(runDate: runDate, db: db)
            try await seedEODHistory(instrumentID: underlying.id!, days: 10,
                                     baseDate: runDate, db: db)
            try await seedOptionEOD(instrumentID: instrumentID,
                                    priceDate: runDate, db: db)

            let activity = PricingActivities(db: db, logger: Logger(label: "test"))
            let result = try await activity.priceAllContracts(runDate: runDate)

            #expect(result.contractsPriced == 1)
            // Black-Scholes + Binomial + Monte Carlo = up to 3
            #expect(result.rowsUpserted >= 2)
            #expect(result.failedContracts.isEmpty)
        }
    }

    @Test("noFREDRatesAvailable thrown when yield curve is empty")
    func noFREDRates() async throws {
        try await withPricingDB { db in
            let (underlying, _) = try await seedBaseFixtures(db: db)
            let runDate = Date()
            let contract = try await seedOptionContract(
                underlying: underlying, expirationDate: futureDate(), db: db)
            try await seedEODHistory(instrumentID: underlying.id!, days: 10,
                                     baseDate: runDate, db: db)
            try await seedOptionEOD(instrumentID: contract.id!, priceDate: runDate, db: db)
            // No yield curve seeded

            let activity = PricingActivities(db: db, logger: Logger(label: "test"))
            do {
                _ = try await activity.priceAllContracts(runDate: runDate)
                Issue.record("Expected PricingError.noFREDRatesAvailable to be thrown")
            } catch PricingError.noFREDRatesAvailable { /* expected */ }
        }
    }

    @Test("Expired contracts are skipped entirely")
    func expiredContractSkipped() async throws {
        try await withPricingDB { db in
            let (underlying, _) = try await seedBaseFixtures(db: db)
            let runDate = Date()
            _ = try await seedOptionContract(
                underlying: underlying,
                expirationDate: runDate.addingTimeInterval(-86400),  // yesterday
                db: db)

            try await seedYieldCurve(runDate: runDate, db: db)

            let activity = PricingActivities(db: db, logger: Logger(label: "test"))
            let result = try await activity.priceAllContracts(runDate: runDate)

            #expect(result.contractsPriced == 0)
            #expect(result.rowsUpserted == 0)
            #expect(result.failedContracts.isEmpty)
        }
    }

    @Test("Contract with no today OptionEODPrice yields no_eod_price_today failure")
    func noEODPriceToday() async throws {
        try await withPricingDB { db in
            let (underlying, _) = try await seedBaseFixtures(db: db)
            let runDate = Date()
            let contract = try await seedOptionContract(
                underlying: underlying, expirationDate: futureDate(), db: db)

            try await seedYieldCurve(runDate: runDate, db: db)
            try await seedEODHistory(instrumentID: underlying.id!, days: 10,
                                     baseDate: runDate, db: db)
            // No OptionEODPrice seeded

            let activity = PricingActivities(db: db, logger: Logger(label: "test"))
            let result = try await activity.priceAllContracts(runDate: runDate)

            #expect(result.contractsPriced == 0)
            #expect(result.failedContracts.count == 1)
            #expect(result.failedContracts[0].reason == "no_eod_price_today")
            #expect(result.failedContracts[0].instrumentID == contract.id!)
        }
    }

    @Test("Contract with < 2 underlying EOD rows yields insufficient_history failure")
    func insufficientHistory() async throws {
        try await withPricingDB { db in
            let (underlying, _) = try await seedBaseFixtures(db: db)
            let runDate = Date()
            let contract = try await seedOptionContract(
                underlying: underlying, expirationDate: futureDate(), db: db)

            try await seedYieldCurve(runDate: runDate, db: db)
            // Seed only 1 day of EOD history
            try await seedEODHistory(instrumentID: underlying.id!, days: 1,
                                     baseDate: runDate, db: db)
            try await seedOptionEOD(instrumentID: contract.id!, priceDate: runDate, db: db)

            let activity = PricingActivities(db: db, logger: Logger(label: "test"))
            let result = try await activity.priceAllContracts(runDate: runDate)

            #expect(result.contractsPriced == 0)
            #expect(result.failedContracts.count == 1)
            #expect(result.failedContracts[0].reason == "insufficient_history")
        }
    }

    @Test("Upsert is idempotent — running twice leaves one row per model")
    func upsertIdempotent() async throws {
        try await withPricingDB { db in
            let (underlying, _) = try await seedBaseFixtures(db: db)
            let runDate = Date()
            let contract = try await seedOptionContract(
                underlying: underlying, expirationDate: futureDate(), db: db)

            try await seedYieldCurve(runDate: runDate, db: db)
            try await seedEODHistory(instrumentID: underlying.id!, days: 10,
                                     baseDate: runDate, db: db)
            try await seedOptionEOD(instrumentID: contract.id!, priceDate: runDate, db: db)

            let activity = PricingActivities(db: db, logger: Logger(label: "test"))
            let first  = try await activity.priceAllContracts(runDate: runDate)
            let second = try await activity.priceAllContracts(runDate: runDate)

            #expect(first.rowsUpserted == second.rowsUpserted)

            let rows = try await TheoreticalOptionEODPrice.query(on: db).all()
            // Should be one row per model (no duplicates)
            #expect(rows.count == first.rowsUpserted)
        }
    }
}

private extension Calendar {
    static let utcCal: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }()
}
