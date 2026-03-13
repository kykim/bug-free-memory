# Engineering Requirements Document (Low-Level)
## Equity Index Options Data Pipeline & Pricer
**Version 1.0 | March 2026 | Confidential**

---

## 1. Overview

This document is the low-level engineering specification for the automated daily options data pipeline. It provides complete Swift implementations, full SQL, Temporal registration code, file structure, and all implementation details required to build the system without further design decisions.

The system is implemented in Swift using Vapor, Fluent ORM, and the Apple Swift Temporal SDK. All components run locally.

---

## 2. File Structure

New files to be created under `Sources/bug-free-memory/`:

```
Sources/bug-free-memory/
├── Workflows/
│   └── DailyPipelineWorkflow.swift
├── Activities/
│   ├── PortfolioActivity.swift
│   ├── EODPriceActivity.swift
│   ├── OptionEODPriceActivity.swift
│   ├── PricingActivity.swift
│   └── RunLogActivity.swift
├── Models/
│   ├── JobRun.swift                       (new)
│   ├── FilteredPositionSet.swift          (new)
│   ├── EODPriceResult.swift               (new)
│   ├── OptionEODResult.swift              (new)
│   ├── PricingResult.swift                (new)
│   ├── RunLogInput.swift                  (new)
│   └── YieldCurve.swift                   (new)
├── Migrations/
│   └── CreateJobRuns.swift                (new)
└── Extensions/
    ├── SchwabClient+Portfolio.swift        (extends existing SchwabClient)
    ├── SchwabClient+OptionQuote.swift      (extends existing SchwabClient)
    ├── OSIParser.swift                     (new)
    ├── OptionContractRegistrar.swift       (new)
    └── MarketCalendar.swift                (new)
```

---

## 3. Temporal Worker Registration

### 3.1 Worker Setup (`configure.swift` addition)

```swift
import Temporalio

// Add to configure(_ app: Application) throws
func configurePipelineWorker(_ app: Application) async throws {
    let client = try await TemporalClient.connect(
        target: .localhost(port: 7233),
        namespace: "default"
    )

    let worker = try TemporalWorker(
        client: client,
        taskQueue: "daily-pipeline",
        workflows: [DailyPipelineWorkflow.self],
        activities: ActivityContext(app: app)
    )

    app.lifecycle.use(
        TemporalWorkerLifecycle(worker: worker)
    )
}
```

### 3.2 Schedule Registration (run once on startup or via CLI)

```swift
func registerPipelineSchedule(client: TemporalClient) async throws {
    let scheduleID = "daily-pipeline-schedule"

    let action = TemporalScheduleAction.startWorkflow(
        DailyPipelineWorkflow.self,
        options: .init(
            id: "daily-pipeline-\(DateFormatter.yyyyMMdd.string(from: Date()))",
            taskQueue: "daily-pipeline"
        )
    )

    let spec = TemporalScheduleSpec(
        cronExpressions: ["0 16 * * 1-5"],
        timezoneName: "America/New_York"
    )

    try await client.createSchedule(
        scheduleID: scheduleID,
        schedule: .init(action: action, spec: spec)
    )
}

extension DateFormatter {
    static let yyyyMMdd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "America/New_York")
        return f
    }()
}
```

---

## 4. Workflow Implementation

### `DailyPipelineWorkflow.swift`

```swift
import Temporalio
import Foundation

struct DailyPipelineWorkflow: TemporalWorkflow {
    static let definition = WorkflowDefinition(name: "DailyPipelineWorkflow")

    func run(context: WorkflowContext) async throws {
        let runDate = Date()
        let startedAt = runDate

        // Early-exit on market holiday
        if MarketCalendar.isHoliday(runDate) {
            context.logger.info("Skipping: market holiday", metadata: [
                "runDate": .string(ISO8601DateFormatter().string(from: runDate))
            ])
            try await context.executeActivity(
                RunLogActivity.self,
                input: RunLogInput(
                    runDate: runDate,
                    status: .skipped,
                    portfolioResult: nil,
                    eodResult: nil,
                    optionEODResult: nil,
                    pricingResult: nil,
                    errorMessages: ["Market holiday — skipped"],
                    startedAt: startedAt
                ),
                options: RunLogActivity.retryPolicy
            )
            return
        }

        var errorMessages: [String] = []

        // 1. Portfolio
        var portfolioResult: FilteredPositionSet? = nil
        do {
            portfolioResult = try await context.executeActivity(
                PortfolioActivity.self,
                input: runDate,
                options: PortfolioActivity.retryPolicy
            )
        } catch {
            errorMessages.append("PortfolioActivity failed: \(error)")
            context.logger.error("PortfolioActivity failed", metadata: ["error": .string("\(error)")])
        }

        // 2. EOD Prices (independent of portfolio result)
        var eodResult: EODPriceResult? = nil
        do {
            eodResult = try await context.executeActivity(
                EODPriceActivity.self,
                input: runDate,
                options: EODPriceActivity.retryPolicy
            )
        } catch {
            errorMessages.append("EODPriceActivity failed: \(error)")
            context.logger.error("EODPriceActivity failed", metadata: ["error": .string("\(error)")])
        }

        // 3. Option EOD Prices (independent of portfolio result)
        var optionEODResult: OptionEODResult? = nil
        do {
            optionEODResult = try await context.executeActivity(
                OptionEODPriceActivity.self,
                input: runDate,
                options: OptionEODPriceActivity.retryPolicy
            )
        } catch {
            errorMessages.append("OptionEODPriceActivity failed: \(error)")
            context.logger.error("OptionEODPriceActivity failed", metadata: ["error": .string("\(error)")])
        }

        // 4. Pricing (only if option EOD succeeded and has rows)
        var pricingResult: PricingResult? = nil
        if let optionEOD = optionEODResult, optionEOD.rowsUpserted > 0 {
            do {
                pricingResult = try await context.executeActivity(
                    PricingActivity.self,
                    input: runDate,
                    options: PricingActivity.retryPolicy
                )
            } catch {
                errorMessages.append("PricingActivity failed: \(error)")
                context.logger.error("PricingActivity failed", metadata: ["error": .string("\(error)")])
            }
        } else {
            errorMessages.append("PricingActivity skipped: no option EOD data")
        }

        // 5. Run log (always)
        let status = RunStatus.determine(
            portfolioResult: portfolioResult,
            eodResult: eodResult,
            optionEODResult: optionEODResult,
            pricingResult: pricingResult,
            errors: errorMessages
        )

        try await context.executeActivity(
            RunLogActivity.self,
            input: RunLogInput(
                runDate: runDate,
                status: status,
                portfolioResult: portfolioResult,
                eodResult: eodResult,
                optionEODResult: optionEODResult,
                pricingResult: pricingResult,
                errorMessages: errorMessages,
                startedAt: startedAt
            ),
            options: RunLogActivity.retryPolicy
        )
    }
}
```

---

## 5. Activity Implementations

### 5.1 `PortfolioActivity.swift`

```swift
import Temporalio
import Fluent
import Vapor

struct PortfolioActivity: TemporalActivity {
    static let definition = ActivityDefinition(name: "PortfolioActivity")

    static let retryPolicy = ActivityOptions(
        scheduleToCloseTimeout: .seconds(300),
        retryPolicy: .init(
            maximumAttempts: 3,
            initialInterval: .seconds(30),
            backoffCoefficient: 2.0
        )
    )

    let db: Database
    let schwabClient: SchwabClient
    let logger: Logger

    func run(runDate: Date) async throws -> FilteredPositionSet {
        logger.info("PortfolioActivity starting", metadata: ["runDate": .string("\(runDate)")])
        let start = Date()

        // 1. Refresh token if needed
        try await schwabClient.refreshTokenIfNeeded(db: db)

        // 2. Fetch positions
        let positions = try await schwabClient.fetchPortfolioPositions()

        // 3. Partition by asset type
        let equityPositions = positions.filter { $0.assetType == .equity }
        let optionPositions = positions.filter { $0.assetType == .option }
        var droppedPositions: [DroppedPosition] = positions
            .filter { $0.assetType == .other }
            .map { DroppedPosition(ticker: $0.ticker, reason: "unsupported_asset_type") }

        // 4. Filter equities
        var equityInstrumentIDs: [UUID] = []
        for position in equityPositions {
            let result = try await Instrument.query(on: db)
                .join(Equity.self, on: \Instrument.$id == \Equity.$id)
                .filter(\Instrument.$ticker == position.ticker)
                .filter(\Instrument.$instrumentType == .equity)
                .filter(\Instrument.$isActive == true)
                .first()
            if let instrument = result {
                equityInstrumentIDs.append(instrument.id!)
            } else {
                droppedPositions.append(DroppedPosition(ticker: position.ticker, reason: "not_in_equities"))
                logger.warning("Equity not in equities table", metadata: ["ticker": .string(position.ticker)])
            }
        }

        // 5. Filter options and register new contracts
        var optionInstrumentIDs: [UUID] = []
        var newContractsRegistered = 0
        for position in optionPositions {
            guard let osiSymbol = position.osiSymbol else {
                droppedPositions.append(DroppedPosition(ticker: position.ticker, reason: "missing_osi_symbol"))
                continue
            }

            let osi: OSIComponents
            do {
                osi = try OSIParser.parse(osiSymbol)
            } catch {
                droppedPositions.append(DroppedPosition(ticker: osiSymbol, reason: "osi_parse_error"))
                logger.warning("OSI parse failed", metadata: ["osi": .string(osiSymbol), "error": .string("\(error)")])
                continue
            }

            // Look up underlying in equities
            guard let underlying = try await Instrument.query(on: db)
                .join(Equity.self, on: \Instrument.$id == \Equity.$id)
                .filter(\Instrument.$ticker == osi.underlyingTicker)
                .filter(\Instrument.$isActive == true)
                .first()
            else {
                droppedPositions.append(DroppedPosition(ticker: osi.underlyingTicker, reason: "underlying_not_in_equities"))
                logger.warning("Option underlying not in equities", metadata: ["underlying": .string(osi.underlyingTicker)])
                continue
            }

            // Check if contract already exists
            if let existing = try await OptionContract.query(on: db)
                .filter(\OptionContract.$osiSymbol == osiSymbol)
                .first() {
                optionInstrumentIDs.append(existing.id!)
            } else {
                // Register new contract
                do {
                    let newID = try await OptionContractRegistrar.register(
                        osi: osi, osiSymbol: osiSymbol,
                        underlyingInstrument: underlying, db: db
                    )
                    optionInstrumentIDs.append(newID)
                    newContractsRegistered += 1
                    logger.info("Registered new option contract", metadata: ["osi": .string(osiSymbol)])
                } catch {
                    logger.error("Failed to register option contract", metadata: [
                        "osi": .string(osiSymbol), "error": .string("\(error)")
                    ])
                    // Do not fail the whole activity for one bad contract
                }
            }
        }

        let duration = Date().timeIntervalSince(start)
        logger.info("PortfolioActivity complete", metadata: [
            "duration": .string(String(format: "%.2fs", duration)),
            "equities": .string("\(equityInstrumentIDs.count)"),
            "options": .string("\(optionInstrumentIDs.count)"),
            "dropped": .string("\(droppedPositions.count)"),
            "newContracts": .string("\(newContractsRegistered)")
        ])

        return FilteredPositionSet(
            equityInstrumentIDs: equityInstrumentIDs,
            optionInstrumentIDs: optionInstrumentIDs,
            newContractsRegistered: newContractsRegistered,
            droppedPositions: droppedPositions,
            runDate: runDate
        )
    }
}
```

---

### 5.2 `EODPriceActivity.swift`

```swift
import Temporalio
import Fluent
import FluentSQL

struct EODPriceActivity: TemporalActivity {
    static let definition = ActivityDefinition(name: "EODPriceActivity")

    static let retryPolicy = ActivityOptions(
        scheduleToCloseTimeout: .seconds(300),
        retryPolicy: .init(
            maximumAttempts: 3,
            initialInterval: .seconds(30),
            backoffCoefficient: 2.0
        )
    )

    let db: Database
    let tiingoClient: TiingoClient
    let logger: Logger

    func run(runDate: Date) async throws -> EODPriceResult {
        logger.info("EODPriceActivity starting", metadata: ["runDate": .string("\(runDate)")])
        let start = Date()

        // Build eligible instrument list: active instruments in equities OR indexes
        let instruments = try await Instrument.query(on: db)
            .filter(\Instrument.$isActive == true)
            .all()
            .asyncFilter { instrument in
                let inEquities = try await Equity.find(instrument.id, on: db) != nil
                let inIndexes  = try await Index.find(instrument.id, on: db) != nil
                return inEquities || inIndexes
            }

        var rowsUpserted = 0
        var failedTickers: [String] = []

        for instrument in instruments {
            do {
                guard let price = try await tiingoClient.fetchEODPrice(
                    ticker: instrument.ticker, date: runDate
                ) else {
                    failedTickers.append(instrument.ticker)
                    logger.warning("No Tiingo data", metadata: ["ticker": .string(instrument.ticker)])
                    continue
                }

                try await upsertEODPrice(
                    instrumentID: instrument.id!,
                    price: price,
                    runDate: runDate,
                    db: db
                )
                rowsUpserted += 1
            } catch let error as TiingoError where error == .authFailure {
                // Auth failure is fatal — rethrow for Temporal retry
                throw error
            } catch {
                failedTickers.append(instrument.ticker)
                logger.error("EOD fetch failed", metadata: [
                    "ticker": .string(instrument.ticker), "error": .string("\(error)")
                ])
            }
        }

        let duration = Date().timeIntervalSince(start)
        logger.info("EODPriceActivity complete", metadata: [
            "duration": .string(String(format: "%.2fs", duration)),
            "upserted": .string("\(rowsUpserted)"),
            "failed": .string("\(failedTickers.count)")
        ])

        return EODPriceResult(
            rowsUpserted: rowsUpserted,
            instrumentsFetched: instruments.count,
            failedTickers: failedTickers,
            source: "tiingo"
        )
    }

    private func upsertEODPrice(
        instrumentID: UUID, price: TiingoEODPrice,
        runDate: Date, db: Database
    ) async throws {
        let id = UUID()
        try await (db as! SQLDatabase).raw("""
            INSERT INTO eod_prices
                (id, instrument_id, price_date, open, high, low, close,
                 adj_close, volume, source, created_at)
            VALUES
                (\(bind: id), \(bind: instrumentID), \(bind: runDate),
                 \(bind: price.open), \(bind: price.high), \(bind: price.low),
                 \(bind: price.close), \(bind: price.adjClose), \(bind: price.volume),
                 'tiingo', NOW())
            ON CONFLICT (instrument_id, price_date)
            DO UPDATE SET
                open      = EXCLUDED.open,
                high      = EXCLUDED.high,
                low       = EXCLUDED.low,
                close     = EXCLUDED.close,
                adj_close = EXCLUDED.adj_close,
                volume    = EXCLUDED.volume,
                source    = EXCLUDED.source
            """).run()
    }
}
```

---

### 5.3 `OptionEODPriceActivity.swift`

```swift
import Temporalio
import Fluent
import FluentSQL
import Foundation

struct OptionEODPriceActivity: TemporalActivity {
    static let definition = ActivityDefinition(name: "OptionEODPriceActivity")

    static let retryPolicy = ActivityOptions(
        scheduleToCloseTimeout: .seconds(600),
        retryPolicy: .init(
            maximumAttempts: 3,
            initialInterval: .seconds(30),
            backoffCoefficient: 2.0
        )
    )

    let db: Database
    let schwabClient: SchwabClient
    let logger: Logger

    func run(runDate: Date) async throws -> OptionEODResult {
        logger.info("OptionEODPriceActivity starting", metadata: ["runDate": .string("\(runDate)")])
        let start = Date()

        // Refresh Schwab token if needed
        try await schwabClient.refreshTokenIfNeeded(db: db)

        // Query non-expired contracts
        let contracts = try await OptionContract.query(on: db)
            .filter(\OptionContract.$expirationDate >= Calendar.current.startOfDay(for: runDate))
            .all()

        // Pre-fetch today's interpolated rate (used for all contracts)
        let yieldCurve = try await YieldCurve.load(db: db, runDate: runDate)

        var rowsUpserted = 0
        var skippedContracts: [SkippedContract] = []

        for contract in contracts {
            guard let osiSymbol = contract.osiSymbol else {
                skippedContracts.append(SkippedContract(
                    instrumentID: contract.id!, osiSymbol: nil, reason: "missing_osi_symbol"
                ))
                continue
            }

            do {
                guard let quote = try await schwabClient.fetchOptionEODPrice(osiSymbol: osiSymbol) else {
                    skippedContracts.append(SkippedContract(
                        instrumentID: contract.id!, osiSymbol: osiSymbol, reason: "no_quote"
                    ))
                    logger.warning("No Schwab quote", metadata: ["osi": .string(osiSymbol)])
                    continue
                }

                let timeToExpiry = contract.timeToExpiry(from: runDate)
                let riskFreeRate = yieldCurve.interpolate(timeToExpiry: timeToExpiry)

                try await upsertOptionEODPrice(
                    instrumentID: contract.id!,
                    quote: quote,
                    riskFreeRate: riskFreeRate,
                    runDate: runDate,
                    db: db
                )
                rowsUpserted += 1
            } catch let error as SchwabError where error == .authFailure {
                throw error  // Fatal — rethrow for Temporal retry
            } catch {
                skippedContracts.append(SkippedContract(
                    instrumentID: contract.id!, osiSymbol: osiSymbol, reason: "fetch_error"
                ))
                logger.error("Option EOD fetch failed", metadata: [
                    "osi": .string(osiSymbol), "error": .string("\(error)")
                ])
            }
        }

        let duration = Date().timeIntervalSince(start)
        logger.info("OptionEODPriceActivity complete", metadata: [
            "duration": .string(String(format: "%.2fs", duration)),
            "processed": .string("\(contracts.count)"),
            "upserted": .string("\(rowsUpserted)"),
            "skipped": .string("\(skippedContracts.count)")
        ])

        return OptionEODResult(
            contractsProcessed: contracts.count,
            rowsUpserted: rowsUpserted,
            skippedContracts: skippedContracts
        )
    }

    private func upsertOptionEODPrice(
        instrumentID: UUID, quote: SchwabOptionQuote,
        riskFreeRate: Double, runDate: Date, db: Database
    ) async throws {
        let id = UUID()
        // NOTE: Do NOT include 'mid' — it is a generated column
        try await (db as! SQLDatabase).raw("""
            INSERT INTO option_eod_prices
                (id, instrument_id, price_date, bid, ask, last, settlement_price,
                 volume, open_interest, implied_volatility, delta, gamma, theta,
                 vega, rho, underlying_price, risk_free_rate, source, created_at)
            VALUES
                (\(bind: id), \(bind: instrumentID), \(bind: runDate),
                 \(bind: quote.bid), \(bind: quote.ask), \(bind: quote.last), \(bind: quote.last),
                 \(bind: quote.volume), \(bind: quote.openInterest),
                 \(bind: quote.impliedVolatility), \(bind: quote.delta), \(bind: quote.gamma),
                 \(bind: quote.theta), \(bind: quote.vega), \(bind: quote.rho),
                 \(bind: quote.underlyingPrice), \(bind: riskFreeRate),
                 'schwab', NOW())
            ON CONFLICT (instrument_id, price_date)
            DO UPDATE SET
                bid                = EXCLUDED.bid,
                ask                = EXCLUDED.ask,
                last               = EXCLUDED.last,
                settlement_price   = EXCLUDED.settlement_price,
                volume             = EXCLUDED.volume,
                open_interest      = EXCLUDED.open_interest,
                implied_volatility = EXCLUDED.implied_volatility,
                delta              = EXCLUDED.delta,
                gamma              = EXCLUDED.gamma,
                theta              = EXCLUDED.theta,
                vega               = EXCLUDED.vega,
                rho                = EXCLUDED.rho,
                underlying_price   = EXCLUDED.underlying_price,
                risk_free_rate     = EXCLUDED.risk_free_rate,
                source             = EXCLUDED.source
            """).run()
    }
}
```

---

### 5.4 `PricingActivity.swift`

```swift
import Temporalio
import Fluent
import FluentSQL
import Foundation

struct PricingActivity: TemporalActivity {
    static let definition = ActivityDefinition(name: "PricingActivity")

    static let retryPolicy = ActivityOptions(
        scheduleToCloseTimeout: .seconds(1800),
        retryPolicy: .init(
            maximumAttempts: 2,
            initialInterval: .seconds(10),
            backoffCoefficient: 1.5
        )
    )

    let db: Database
    let logger: Logger

    func run(runDate: Date) async throws -> PricingResult {
        logger.info("PricingActivity starting", metadata: ["runDate": .string("\(runDate)")])
        let start = Date()

        // Load yield curve once — shared across all concurrent tasks
        let yieldCurve = try await YieldCurve.load(db: db, runDate: runDate)
        // Fatal if no FRED rates available
        guard !yieldCurve.points.isEmpty else {
            throw PricingError.noFREDRatesAvailable(runDate: runDate)
        }

        // Load non-expired contracts
        let contracts = try await OptionContract.query(on: db)
            .filter(\OptionContract.$expirationDate >= Calendar.current.startOfDay(for: runDate))
            .with(\.$underlying)
            .all()

        var contractsPriced = 0
        var rowsUpserted = 0
        var failedContracts: [FailedContract] = []

        // Price contracts concurrently
        let results = try await withThrowingTaskGroup(
            of: ContractPricingOutcome.self
        ) { group in
            for contract in contracts {
                group.addTask {
                    try await self.priceContract(
                        contract: contract,
                        yieldCurve: yieldCurve,
                        runDate: runDate
                    )
                }
            }
            var outcomes: [ContractPricingOutcome] = []
            for try await outcome in group {
                outcomes.append(outcome)
            }
            return outcomes
        }

        for outcome in results {
            switch outcome {
            case .success(let count):
                contractsPriced += 1
                rowsUpserted += count
            case .failure(let failed):
                failedContracts.append(failed)
                logger.warning("Contract pricing failed", metadata: [
                    "instrumentID": .string("\(failed.instrumentID)"),
                    "reason": .string(failed.reason)
                ])
            }
        }

        let duration = Date().timeIntervalSince(start)
        logger.info("PricingActivity complete", metadata: [
            "duration": .string(String(format: "%.2fs", duration)),
            "priced": .string("\(contractsPriced)"),
            "rows": .string("\(rowsUpserted)"),
            "failed": .string("\(failedContracts.count)")
        ])

        return PricingResult(
            contractsPriced: contractsPriced,
            rowsUpserted: rowsUpserted,
            failedContracts: failedContracts
        )
    }

    // MARK: - Per-contract pricing

    private enum ContractPricingOutcome {
        case success(rowsUpserted: Int)
        case failure(FailedContract)
    }

    private func priceContract(
        contract: OptionContract,
        yieldCurve: YieldCurve,
        runDate: Date
    ) async throws -> ContractPricingOutcome {

        let instrumentID = contract.id!

        // a. Fetch today's option EOD price (for IV)
        guard let optionEOD = try await OptionEODPrice.query(on: db)
            .filter(\OptionEODPrice.$instrument.$id == instrumentID)
            .filter(\OptionEODPrice.$priceDate == Calendar.current.startOfDay(for: runDate))
            .first()
        else {
            return .failure(FailedContract(instrumentID: instrumentID, reason: "no_eod_price_today"))
        }

        // b. Fetch underlying EOD price history (last 31 days)
        let history = try await EODPrice.query(on: db)
            .filter(\EODPrice.$instrument.$id == contract.$underlying.id)
            .filter(\EODPrice.$priceDate >= Calendar.current.date(byAdding: .day, value: -31, to: runDate)!)
            .sort(\EODPrice.$priceDate, .ascending)
            .all()

        guard history.count >= 2 else {
            return .failure(FailedContract(instrumentID: instrumentID, reason: "insufficient_history"))
        }

        let currentPrice = history.last!

        // c. Interpolate risk-free rate
        let timeToExpiry = contract.timeToExpiry(from: runDate)
        let r = yieldCurve.interpolate(timeToExpiry: timeToExpiry)

        // d. Run all three pricers
        let bsResult  = contract.blackScholesPrice(
            currentPrice: currentPrice, priceHistory: history, riskFreeRate: r
        )
        let binResult = contract.binomialPrice(
            currentPrice: currentPrice, priceHistory: history, riskFreeRate: r
        )
        let mcResult  = contract.monteCarloPrice(
            currentPrice: currentPrice, priceHistory: history, riskFreeRate: r
        )

        // e. Build and upsert records for each non-nil result
        var rowsUpserted = 0
        let priceDate = Calendar.current.startOfDay(for: runDate)
        let iv = optionEOD.impliedVolatility

        if let bs = bsResult {
            var record = TheoreticalOptionEODPrice.from(
                result: bs, instrumentID: instrumentID,
                priceDate: priceDate, riskFreeRate: r,
                pricingModel: .blackScholes, source: "pipeline"
            )
            record.impliedVolatility = iv
            try await upsertTheoreticalPrice(record, db: db)
            rowsUpserted += 1
        }
        if let bin = binResult {
            var record = TheoreticalOptionEODPrice.from(
                result: bin, instrumentID: instrumentID,
                priceDate: priceDate, riskFreeRate: r,
                pricingModel: .binomial, source: "pipeline"
            )
            record.impliedVolatility = iv
            try await upsertTheoreticalPrice(record, db: db)
            rowsUpserted += 1
        }
        if let mc = mcResult {
            var record = TheoreticalOptionEODPrice.from(
                result: mc, instrumentID: instrumentID,
                priceDate: priceDate, riskFreeRate: r,
                source: "pipeline"
            )
            record.impliedVolatility = iv
            try await upsertTheoreticalPrice(record, db: db)
            rowsUpserted += 1
        }

        if rowsUpserted == 0 {
            return .failure(FailedContract(instrumentID: instrumentID, reason: "all_pricers_returned_nil"))
        }

        return .success(rowsUpserted: rowsUpserted)
    }

    private func upsertTheoreticalPrice(
        _ record: TheoreticalOptionEODPrice, db: Database
    ) async throws {
        try await (db as! SQLDatabase).raw("""
            INSERT INTO theoretical_option_eod_prices
                (id, instrument_id, price_date, price, settlement_price,
                 implied_volatility, historical_volatility, risk_free_rate,
                 underlying_price, delta, gamma, theta, vega, rho,
                 model, model_detail, source, created_at)
            VALUES
                (\(bind: record.id ?? UUID()),
                 \(bind: record.$instrument.id),
                 \(bind: record.priceDate),
                 \(bind: record.price),
                 \(bind: record.settlementPrice),
                 \(bind: record.impliedVolatility),
                 \(bind: record.historicalVolatility),
                 \(bind: record.riskFreeRate),
                 \(bind: record.underlyingPrice),
                 \(bind: record.delta), \(bind: record.gamma),
                 \(bind: record.theta), \(bind: record.vega), \(bind: record.rho),
                 \(bind: record.model.rawValue),
                 \(bind: record.modelDetail),
                 \(bind: record.source),
                 NOW())
            ON CONFLICT (instrument_id, price_date, model)
            DO UPDATE SET
                price                = EXCLUDED.price,
                settlement_price     = EXCLUDED.settlement_price,
                implied_volatility   = EXCLUDED.implied_volatility,
                historical_volatility = EXCLUDED.historical_volatility,
                risk_free_rate       = EXCLUDED.risk_free_rate,
                underlying_price     = EXCLUDED.underlying_price,
                delta                = EXCLUDED.delta,
                gamma                = EXCLUDED.gamma,
                theta                = EXCLUDED.theta,
                vega                 = EXCLUDED.vega,
                rho                  = EXCLUDED.rho,
                model_detail         = EXCLUDED.model_detail,
                source               = EXCLUDED.source
            """).run()
    }
}

enum PricingError: Error {
    case noFREDRatesAvailable(runDate: Date)
}
```

---

### 5.5 `RunLogActivity.swift`

```swift
import Temporalio
import Fluent

struct RunLogActivity: TemporalActivity {
    static let definition = ActivityDefinition(name: "RunLogActivity")

    static let retryPolicy = ActivityOptions(
        scheduleToCloseTimeout: .seconds(60),
        retryPolicy: .init(
            maximumAttempts: 5,
            initialInterval: .seconds(5),
            backoffCoefficient: 1.5
        )
    )

    let db: Database
    let logger: Logger

    func run(input: RunLogInput) async throws {
        let completedAt = Date()

        let jobRun = JobRun()
        jobRun.id = UUID()
        jobRun.runDate = Calendar.current.startOfDay(for: input.runDate)
        jobRun.status = input.status.rawValue
        jobRun.startedAt = input.startedAt
        jobRun.completedAt = completedAt
        jobRun.equitiesFetched = input.eodResult?.rowsUpserted
        jobRun.optionsFetched = input.optionEODResult?.rowsUpserted
        jobRun.contractsPriced = input.pricingResult?.contractsPriced
        jobRun.theoreticalRows = input.pricingResult?.rowsUpserted
        jobRun.newContracts = input.portfolioResult?.newContractsRegistered
        jobRun.droppedPositions = input.portfolioResult?.droppedPositions.map { "\($0.ticker): \($0.reason)" }
        jobRun.failedTickers = input.eodResult?.failedTickers
        jobRun.skippedContracts = input.optionEODResult?.skippedContracts.map { $0.osiSymbol ?? "\($0.instrumentID)" }
        jobRun.failedContracts = input.pricingResult?.failedContracts.map { $0.instrumentID }
        jobRun.errorMessages = input.errorMessages.isEmpty ? nil : input.errorMessages
        jobRun.sourceUsed = input.eodResult?.source

        // Upsert on run_date — handles re-runs on same day
        try await (db as! SQLDatabase).raw("""
            INSERT INTO job_runs
                (id, run_date, status, started_at, completed_at,
                 equities_fetched, options_fetched, contracts_priced, theoretical_rows,
                 new_contracts, dropped_positions, failed_tickers, skipped_contracts,
                 failed_contracts, error_messages, source_used)
            VALUES
                (\(bind: jobRun.id!), \(bind: jobRun.runDate), \(bind: jobRun.status),
                 \(bind: jobRun.startedAt), \(bind: jobRun.completedAt),
                 \(bind: jobRun.equitiesFetched), \(bind: jobRun.optionsFetched),
                 \(bind: jobRun.contractsPriced), \(bind: jobRun.theoreticalRows),
                 \(bind: jobRun.newContracts), \(bind: jobRun.droppedPositions),
                 \(bind: jobRun.failedTickers), \(bind: jobRun.skippedContracts),
                 \(bind: jobRun.failedContracts), \(bind: jobRun.errorMessages),
                 \(bind: jobRun.sourceUsed))
            ON CONFLICT (run_date)
            DO UPDATE SET
                status            = EXCLUDED.status,
                completed_at      = EXCLUDED.completed_at,
                equities_fetched  = EXCLUDED.equities_fetched,
                options_fetched   = EXCLUDED.options_fetched,
                contracts_priced  = EXCLUDED.contracts_priced,
                theoretical_rows  = EXCLUDED.theoretical_rows,
                new_contracts     = EXCLUDED.new_contracts,
                dropped_positions = EXCLUDED.dropped_positions,
                failed_tickers    = EXCLUDED.failed_tickers,
                skipped_contracts = EXCLUDED.skipped_contracts,
                failed_contracts  = EXCLUDED.failed_contracts,
                error_messages    = EXCLUDED.error_messages,
                source_used       = EXCLUDED.source_used
            """).run()

        logger.info("RunLogActivity complete", metadata: [
            "runDate": .string("\(input.runDate)"),
            "status": .string(input.status.rawValue),
            "duration": .string(String(format: "%.2fs", completedAt.timeIntervalSince(input.startedAt)))
        ])
    }
}
```

---

## 6. Support Types

### 6.1 `YieldCurve.swift`

```swift
import Fluent
import Foundation

struct YieldCurve: Sendable {
    struct Point: Sendable {
        let tenorYears: Double
        let continuousRate: Double
    }

    let points: [Point]   // sorted ascending by tenorYears
    let observationDate: Date

    // Load the most recent yield curve on or before runDate
    static func load(db: Database, runDate: Date) async throws -> YieldCurve {
        // Find most recent observation date
        guard let latestDate = try await (db as! SQLDatabase).raw("""
            SELECT MAX(observation_date) AS latest
            FROM fred_yields
            WHERE observation_date <= \(bind: runDate)
            """)
            .first(decoding: LatestDateRow.self)
            .map(\.latest)
        else {
            return YieldCurve(points: [], observationDate: runDate)
        }

        let rows = try await FREDYield.query(on: db)
            .filter(\FREDYield.$observationDate == latestDate)
            .filter(\FREDYield.$continuousRate != nil)
            .sort(\FREDYield.$tenorYears, .ascending)
            .all()

        let points = rows.compactMap { row -> Point? in
            guard let rate = row.continuousRate else { return nil }
            return Point(tenorYears: row.tenorYears, continuousRate: rate)
        }

        return YieldCurve(points: points, observationDate: latestDate)
    }

    // Linear interpolation with flat extrapolation at boundaries
    func interpolate(timeToExpiry T: Double) -> Double {
        guard !points.isEmpty else { return 0.05 }  // fallback default
        guard points.count > 1 else { return points[0].continuousRate }

        if T <= points.first!.tenorYears { return points.first!.continuousRate }
        if T >= points.last!.tenorYears  { return points.last!.continuousRate }

        for i in 0..<(points.count - 1) {
            let lo = points[i], hi = points[i + 1]
            if T >= lo.tenorYears && T <= hi.tenorYears {
                let weight = (T - lo.tenorYears) / (hi.tenorYears - lo.tenorYears)
                return lo.continuousRate + weight * (hi.continuousRate - lo.continuousRate)
            }
        }
        return points.last!.continuousRate
    }

    private struct LatestDateRow: Decodable {
        let latest: Date
    }
}
```

### 6.2 `OSIParser.swift`

```swift
import Foundation

enum OSIParseError: Error, LocalizedError {
    case invalidLength(actual: Int)
    case invalidExpiryFormat(String)
    case invalidOptionType(Character)
    case invalidStrike(String)

    var errorDescription: String? {
        switch self {
        case .invalidLength(let n):     return "OSI symbol must be 21 chars, got \(n)"
        case .invalidExpiryFormat(let s): return "Cannot parse expiry: \(s)"
        case .invalidOptionType(let c): return "Option type must be C or P, got \(c)"
        case .invalidStrike(let s):     return "Cannot parse strike: \(s)"
        }
    }
}

struct OSIComponents {
    let underlyingTicker: String
    let expirationDate: Date
    let optionType: OptionType
    let strikePrice: Double
}

enum OSIParser {
    // OSI format (21 chars): UUUUUU YYMMDD T KKKKKKKK
    // U = underlying (6, right-padded), Y/M/D = expiry, T = C/P, K = strike × 1000 (8 digits)
    static func parse(_ osi: String) throws -> OSIComponents {
        let s = osi.replacingOccurrences(of: " ", with: "")   // normalise any spaces
        let padded = osi   // keep original for field extraction

        guard osi.count == 21 else {
            throw OSIParseError.invalidLength(actual: osi.count)
        }

        let chars = Array(osi)

        // Underlying: chars 0-5, trim trailing spaces
        let underlying = String(chars[0..<6]).trimmingCharacters(in: .whitespaces)

        // Expiry: chars 6-11 YYMMDD
        let expiryStr = String(chars[6..<12])
        let expiryFormatter = DateFormatter()
        expiryFormatter.dateFormat = "yyMMdd"
        expiryFormatter.timeZone = TimeZone(identifier: "America/New_York")
        guard let expiry = expiryFormatter.date(from: expiryStr) else {
            throw OSIParseError.invalidExpiryFormat(expiryStr)
        }

        // Option type: char 12
        let typeChar = chars[12]
        let optionType: OptionType
        switch typeChar {
        case "C": optionType = .call
        case "P": optionType = .put
        default:  throw OSIParseError.invalidOptionType(typeChar)
        }

        // Strike: chars 13-20, divide by 1000
        let strikeStr = String(chars[13..<21])
        guard let strikeRaw = Double(strikeStr) else {
            throw OSIParseError.invalidStrike(strikeStr)
        }
        let strike = strikeRaw / 1000.0

        return OSIComponents(
            underlyingTicker: underlying,
            expirationDate: expiry,
            optionType: optionType,
            strikePrice: strike
        )
    }
}
```

### 6.3 `OptionContractRegistrar.swift`

```swift
import Fluent
import Foundation

enum OptionContractRegistrarError: Error {
    case uniqueViolation
}

enum OptionContractRegistrar {
    static func register(
        osi: OSIComponents,
        osiSymbol: String,
        underlyingInstrument: Instrument,
        db: Database
    ) async throws -> UUID {
        let isIndex = underlyingInstrument.instrumentType == .index
        let instrumentType: InstrumentType = isIndex ? .indexOption : .equityOption
        let exerciseStyle: ExerciseStyle   = isIndex ? .european   : .american
        let settlementType                 = isIndex ? "cash"      : "physical"

        let expiryStr = DateFormatter.yyyyMMdd.string(from: osi.expirationDate)
        let name = "\(osi.underlyingTicker) \(osi.strikePrice) \(osi.optionType.rawValue.uppercased()) \(expiryStr)"

        // Guard against duplicate instruments (race condition or re-run)
        if let existing = try await Instrument.query(on: db)
            .filter(\Instrument.$ticker == osiSymbol)
            .first() {
            return existing.id!
        }

        let instrument = Instrument(
            instrumentType: instrumentType,
            ticker: osiSymbol,
            name: name,
            currencyCode: "USD",
            isActive: true
        )
        do {
            try await instrument.save(on: db)
        } catch let error as PSQLError where error.code == .uniqueViolation {
            // Lost race — fetch the existing row
            if let existing = try await Instrument.query(on: db)
                .filter(\Instrument.$ticker == osiSymbol).first() {
                return existing.id!
            }
            throw error
        }

        let contract = OptionContract(
            instrumentID: instrument.id!,
            underlyingID: underlyingInstrument.id!,
            optionType: osi.optionType,
            exerciseStyle: exerciseStyle,
            strikePrice: osi.strikePrice,
            expirationDate: osi.expirationDate,
            contractMultiplier: 100,
            settlementType: settlementType,
            osiSymbol: osiSymbol
        )
        try await contract.save(on: db)

        return instrument.id!
    }
}
```

### 6.4 `MarketCalendar.swift`

```swift
import Foundation

enum MarketCalendar {
    // US market holidays — update annually via CFG-02
    static let holidays2026: Set<String> = [
        "20260101",  // New Year's Day
        "20260119",  // MLK Day
        "20260216",  // Presidents' Day
        "20260403",  // Good Friday
        "20260525",  // Memorial Day
        "20260703",  // Independence Day (observed)
        "20260907",  // Labor Day
        "20261126",  // Thanksgiving
        "20261225",  // Christmas
    ]

    static func isHoliday(_ date: Date) -> Bool {
        let key = DateFormatter.yyyyMMdd.string(from: date)
        return holidays2026.contains(key)
    }

    static func isTradingDay(_ date: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: date)
        let isWeekend = weekday == 1 || weekday == 7
        return !isWeekend && !isHoliday(date)
    }
}
```

---

## 7. Pipeline Result Types

### `FilteredPositionSet.swift`
```swift
struct FilteredPositionSet: Codable, Sendable {
    let equityInstrumentIDs: [UUID]
    let optionInstrumentIDs: [UUID]
    let newContractsRegistered: Int
    let droppedPositions: [DroppedPosition]
    let runDate: Date
}

struct DroppedPosition: Codable, Sendable {
    let ticker: String
    let reason: String
    // Reason values: "not_in_equities" | "underlying_not_in_equities"
    //                | "unsupported_asset_type" | "missing_osi_symbol"
    //                | "osi_parse_error"
}
```

### `EODPriceResult.swift`
```swift
struct EODPriceResult: Codable, Sendable {
    let rowsUpserted: Int
    let instrumentsFetched: Int
    let failedTickers: [String]
    let source: String
}
```

### `OptionEODResult.swift`
```swift
struct OptionEODResult: Codable, Sendable {
    let contractsProcessed: Int
    let rowsUpserted: Int
    let skippedContracts: [SkippedContract]
}

struct SkippedContract: Codable, Sendable {
    let instrumentID: UUID
    let osiSymbol: String?
    let reason: String
    // Reason values: "no_quote" | "fetch_error" | "missing_osi_symbol"
}
```

### `PricingResult.swift`
```swift
struct PricingResult: Codable, Sendable {
    let contractsPriced: Int
    let rowsUpserted: Int
    let failedContracts: [FailedContract]
}

struct FailedContract: Codable, Sendable {
    let instrumentID: UUID
    let reason: String
    // Reason values: "no_eod_price_today" | "insufficient_history"
    //                | "no_fred_rate" | "all_pricers_returned_nil"
}
```

### `RunLogInput.swift`
```swift
struct RunLogInput: Codable, Sendable {
    let runDate: Date
    let status: RunStatus
    let portfolioResult: FilteredPositionSet?
    let eodResult: EODPriceResult?
    let optionEODResult: OptionEODResult?
    let pricingResult: PricingResult?
    let errorMessages: [String]
    let startedAt: Date
}

enum RunStatus: String, Codable, Sendable {
    case success, partial, failed, skipped

    static func determine(
        portfolioResult: FilteredPositionSet?,
        eodResult: EODPriceResult?,
        optionEODResult: OptionEODResult?,
        pricingResult: PricingResult?,
        errors: [String]
    ) -> RunStatus {
        if errors.isEmpty { return .success }
        let allFailed = portfolioResult == nil && optionEODResult == nil
        if allFailed { return .failed }
        return .partial
    }
}
```

---

## 8. Schwab Client Extensions

### `SchwabClient+Portfolio.swift`
```swift
extension SchwabClient {
    func fetchPortfolioPositions() async throws -> [SchwabPosition] {
        // GET /trader/v1/accounts/{accountNumber}/positions
        let response = try await get(path: "/trader/v1/accounts/\(accountNumber)/positions")
        return try JSONDecoder().decode([SchwabPosition].self, from: response)
    }

    func refreshTokenIfNeeded(db: Database) async throws {
        guard let token = try await OAuthToken.query(on: db)
            .filter(\OAuthToken.$provider == "schwab")
            .first()
        else { throw SchwabError.noTokenFound }

        if token.isExpired(buffer: 60) {
            let refreshed = try await refreshToken(refreshToken: token.refreshToken ?? "")
            token.accessToken = refreshed.accessToken
            token.expiresAt = refreshed.expiresAt
            if let newRefresh = refreshed.refreshToken {
                token.refreshToken = newRefresh
            }
            try await token.save(on: db)
        }
    }
}

struct SchwabPosition: Codable {
    let ticker: String
    let assetType: SchwabAssetType
    let quantity: Double
    let osiSymbol: String?
    let marketValue: Double?

    enum CodingKeys: String, CodingKey {
        case ticker = "symbol"
        case assetType = "assetType"
        case quantity
        case osiSymbol = "symbol"    // OSI symbol for options
        case marketValue
    }
}

enum SchwabAssetType: String, Codable {
    case equity  = "EQUITY"
    case option  = "OPTION"
    case other

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "EQUITY": self = .equity
        case "OPTION": self = .option
        default:       self = .other
        }
    }
}

enum SchwabError: Error {
    case authFailure
    case noTokenFound
    case rateLimitExceeded
}
```

### `SchwabClient+OptionQuote.swift`
```swift
extension SchwabClient {
    func fetchOptionEODPrice(osiSymbol: String) async throws -> SchwabOptionQuote? {
        // GET /marketdata/v1/chains?symbol=TICKER&strikeCount=1&includeUnderlyingQuote=true
        // For precise lookup by OSI, use the quotes endpoint:
        // GET /marketdata/v1/quotes?symbols={osiSymbol}
        let response = try await get(path: "/marketdata/v1/quotes?symbols=\(osiSymbol)")
        let decoded = try JSONDecoder().decode([String: SchwabOptionQuote].self, from: response)
        return decoded[osiSymbol]
    }
}

struct SchwabOptionQuote: Codable {
    let bid: Double?
    let ask: Double?
    let last: Double?
    let volume: Int?
    let openInterest: Int?
    let impliedVolatility: Double?
    let underlyingPrice: Double?
    let delta: Double?
    let gamma: Double?
    let theta: Double?
    let vega: Double?
    let rho: Double?

    enum CodingKeys: String, CodingKey {
        case bid, ask, last, volume
        case openInterest     = "openInterest"
        case impliedVolatility = "volatility"
        case underlyingPrice  = "underlyingPrice"
        case delta, gamma, theta, vega, rho
    }
}
```

---

## 9. `job_runs` Migration & Model

### `CreateJobRuns.swift`
```swift
import Fluent

struct CreateJobRuns: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema("job_runs")
            .id()
            .field("run_date",           .date,    .required)
            .field("status",             .string,  .required)
            .field("equities_fetched",   .int)
            .field("options_fetched",    .int)
            .field("contracts_priced",   .int)
            .field("theoretical_rows",   .int)
            .field("new_contracts",      .int)
            .field("dropped_positions",  .array(of: .string))
            .field("failed_tickers",     .array(of: .string))
            .field("skipped_contracts",  .array(of: .string))
            .field("failed_contracts",   .array(of: .uuid))
            .field("error_messages",     .array(of: .string))
            .field("source_used",        .string)
            .field("started_at",         .datetime, .required)
            .field("completed_at",       .datetime)
            .unique(on: "run_date")
            .create()
    }

    func revert(on database: any Database) async throws {
        try await database.schema("job_runs").delete()
    }
}
```

### `JobRun.swift`
```swift
import Fluent
import Vapor

final class JobRun: Model, Content, @unchecked Sendable {
    static let schema = "job_runs"

    @ID var id: UUID?

    @Field(key: "run_date")                    var runDate: Date
    @Field(key: "status")                      var status: String
    @OptionalField(key: "equities_fetched")    var equitiesFetched: Int?
    @OptionalField(key: "options_fetched")     var optionsFetched: Int?
    @OptionalField(key: "contracts_priced")    var contractsPriced: Int?
    @OptionalField(key: "theoretical_rows")    var theoreticalRows: Int?
    @OptionalField(key: "new_contracts")       var newContracts: Int?
    @OptionalField(key: "dropped_positions")   var droppedPositions: [String]?
    @OptionalField(key: "failed_tickers")      var failedTickers: [String]?
    @OptionalField(key: "skipped_contracts")   var skippedContracts: [String]?
    @OptionalField(key: "failed_contracts")    var failedContracts: [UUID]?
    @OptionalField(key: "error_messages")      var errorMessages: [String]?
    @OptionalField(key: "source_used")         var sourceUsed: String?
    @Field(key: "started_at")                  var startedAt: Date
    @OptionalField(key: "completed_at")        var completedAt: Date?

    init() {}
}
```

---

## 10. Open Engineering Questions

- Should `EODPriceActivity` and `OptionEODPriceActivity` run concurrently within the workflow in v1.0? They are independent — concurrent execution would reduce total wall time but adds workflow complexity.
- For contracts with `reason: "no_quote"`, should the activity retry with a short delay (e.g. 5s) before accepting the skip, in case Schwab data is slightly delayed at 4:00 PM ET?
- Should the `job_runs` unique constraint be relaxed from `run_date` alone to allow recording both a failed and a subsequent successful run on the same date?
- CBOE DataShop (DS-03): defer all engineering until free tier is confirmed.

---

*— End of Document —*
