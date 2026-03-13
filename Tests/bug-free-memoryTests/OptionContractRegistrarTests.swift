//
//  OptionContractRegistrarTests.swift
//  bug-free-memory
//
//  TICKET-007: OptionContractRegistrar unit tests.
//  Runs against an in-memory SQLite database.
//

import Testing
import Foundation
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import bug_free_memory

// MARK: - Test DB helper

private func withRegistrarDB(_ body: (any Database) async throws -> Void) async throws {
    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateCurrencies())
        app.migrations.add(CreateExchanges())
        app.migrations.add(CreateInstruments())
        app.migrations.add(CreateOptionContracts())
        try await app.autoMigrate()
    }) { app in
        try await body(app.db)
    }
}

// MARK: - Seed helpers

private func seedCurrencyAndExchange(db: any Database) async throws -> (currency: Currency, exchange: Exchange) {
    let currency = Currency(currencyCode: "USD", name: "US Dollar")
    try await currency.save(on: db)

    let exchange = Exchange(micCode: "XNAS", name: "NASDAQ", countryCode: "US", timezone: "America/New_York")
    try await exchange.save(on: db)

    return (currency, exchange)
}

private func makeEquityUnderlying(exchangeID: UUID, db: any Database) async throws -> Instrument {
    let equity = Instrument(instrumentType: .equity, ticker: "AAPL", name: "Apple Inc.",
                            exchangeID: exchangeID, currencyCode: "USD")
    try await equity.save(on: db)
    return equity
}

private func makeIndexUnderlying(exchangeID: UUID, db: any Database) async throws -> Instrument {
    let index = Instrument(instrumentType: .index, ticker: "SPX", name: "S&P 500",
                           exchangeID: exchangeID, currencyCode: "USD")
    try await index.save(on: db)
    return index
}

private func parseOSI(_ symbol: String) throws -> OSIComponents {
    try OSIParser.parse(symbol)
}

// MARK: - Tests

@Suite("OptionContractRegistrar")
struct OptionContractRegistrarTests {

    // MARK: Equity option

    @Test("Equity underlying → equityOption instrument, american exercise, physical settlement")
    func equityOptionDefaults() async throws {
        try await withRegistrarDB { db in
            let (_, exchange) = try await seedCurrencyAndExchange(db: db)
            let underlying = try await makeEquityUnderlying(exchangeID: exchange.id!, db: db)

            let osiSymbol = "AAPL  260320C00175000"
            let osi = try parseOSI(osiSymbol)
            let id = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)

            let instrument = try await Instrument.find(id, on: db)!
            #expect(instrument.instrumentType == .equityOption)
            #expect(instrument.ticker == osiSymbol)

            let contract = try await OptionContract.find(id, on: db)!
            #expect(contract.exerciseStyle == .american)
            #expect(contract.settlementType == "physical")
            #expect(contract.optionType == .call)
            #expect(abs(contract.strikePrice - 175.0) < 0.001)
            #expect(contract.contractMultiplier == 100)
            #expect(contract.osiSymbol == osiSymbol)
        }
    }

    // MARK: Index option

    @Test("Index underlying → indexOption instrument, european exercise, cash settlement")
    func indexOptionDefaults() async throws {
        try await withRegistrarDB { db in
            let (_, exchange) = try await seedCurrencyAndExchange(db: db)
            let underlying = try await makeIndexUnderlying(exchangeID: exchange.id!, db: db)

            let osiSymbol = "SPX   261218C05500000"
            let osi = try parseOSI(osiSymbol)
            let id = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)

            let instrument = try await Instrument.find(id, on: db)!
            #expect(instrument.instrumentType == .indexOption)

            let contract = try await OptionContract.find(id, on: db)!
            #expect(contract.exerciseStyle == .european)
            #expect(contract.settlementType == "cash")
        }
    }

    // MARK: Idempotency

    @Test("Calling register twice returns the same UUID without creating duplicates")
    func idempotentOnSecondCall() async throws {
        try await withRegistrarDB { db in
            let (_, exchange) = try await seedCurrencyAndExchange(db: db)
            let underlying = try await makeEquityUnderlying(exchangeID: exchange.id!, db: db)

            let osiSymbol = "AAPL  260320C00175000"
            let osi = try parseOSI(osiSymbol)

            let id1 = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)
            let id2 = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)

            #expect(id1 == id2)

            // Only one Instrument and one OptionContract should exist for this OSI
            let instrumentCount = try await Instrument.query(on: db)
                .filter(\.$ticker == osiSymbol).count()
            #expect(instrumentCount == 1)

            let contractCount = try await OptionContract.query(on: db)
                .filter(\.$osiSymbol == osiSymbol).count()
            #expect(contractCount == 1)
        }
    }

    @Test("Returns existing Instrument id when ticker is already registered")
    func returnsExistingInstrumentID() async throws {
        try await withRegistrarDB { db in
            let (_, exchange) = try await seedCurrencyAndExchange(db: db)
            let underlying = try await makeEquityUnderlying(exchangeID: exchange.id!, db: db)

            // Pre-register the instrument manually (simulates a prior run)
            let osiSymbol = "AAPL  260320P00150000"
            let preExisting = Instrument(
                instrumentType: .equityOption, ticker: osiSymbol, name: osiSymbol,
                exchangeID: exchange.id!, currencyCode: "USD")
            try await preExisting.save(on: db)

            let osi = try parseOSI(osiSymbol)
            let returnedID = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)

            #expect(returnedID == preExisting.id!)
        }
    }

    // MARK: Put option

    @Test("Correctly registers a put option")
    func putOption() async throws {
        try await withRegistrarDB { db in
            let (_, exchange) = try await seedCurrencyAndExchange(db: db)
            let underlying = try await makeEquityUnderlying(exchangeID: exchange.id!, db: db)

            let osiSymbol = "AAPL  260320P00150000"
            let osi = try parseOSI(osiSymbol)
            let id = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)

            let contract = try await OptionContract.find(id, on: db)!
            #expect(contract.optionType == .put)
            #expect(abs(contract.strikePrice - 150.0) < 0.001)
        }
    }

    // MARK: Underlying linkage

    @Test("OptionContract links back to the correct underlying instrument")
    func underlyingLinkage() async throws {
        try await withRegistrarDB { db in
            let (_, exchange) = try await seedCurrencyAndExchange(db: db)
            let underlying = try await makeEquityUnderlying(exchangeID: exchange.id!, db: db)

            let osiSymbol = "AAPL  260320C00175000"
            let osi = try parseOSI(osiSymbol)
            let id = try await OptionContractRegistrar.register(
                osi: osi, osiSymbol: osiSymbol, underlyingInstrument: underlying, db: db)

            let contract = try await OptionContract.find(id, on: db)!
            #expect(contract.$underlying.id == underlying.id!)
        }
    }
}
