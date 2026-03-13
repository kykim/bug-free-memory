//
//  PortfolioActivity.swift
//  bug-free-memory
//
//  Temporal activity that downloads Schwab positions, registers new option
//  contracts, and returns a FilteredPositionSet.
//

import Fluent
import Foundation
import Logging
import Temporal

@ActivityContainer
public struct PortfolioActivities {

    private let db: any Database
    private let schwabClient: SchwabClient
    private let logger: Logger

    public init(db: any Database, schwabClient: SchwabClient, logger: Logger) {
        self.db = db
        self.schwabClient = schwabClient
        self.logger = logger
    }

    @Activity(
        retryPolicy: RetryPolicy(
            initialInterval: .seconds(30),
            backoffCoefficient: 2.0,
            maximumAttempts: 3
        ),
        scheduleToCloseTimeout: .seconds(300)
    )
    public func fetchPortfolioPositions(runDate: Date) async throws -> FilteredPositionSet {
        let start = Date()
        logger.info("[PortfolioActivity] starting for runDate=\(runDate)")

        // 1. Refresh token if needed
        try await schwabClient.refreshTokenIfNeeded(db: db)

        // 2. Fetch positions
        let positions = try await schwabClient.fetchPortfolioPositions()

        var equityInstrumentIDs: [UUID] = []
        var optionInstrumentIDs: [UUID] = []
        var droppedPositions: [DroppedPosition] = []
        var newContractsRegistered = 0

        let equityPositions = positions.filter { $0.assetType == .equity }
        let optionPositions  = positions.filter { $0.assetType == .option }
        let otherPositions   = positions.filter { $0.assetType == .other }

        // Drop unsupported asset types
        for p in otherPositions {
            logger.warning("[PortfolioActivity] dropping \(p.ticker): unsupported_asset_type")
            droppedPositions.append(DroppedPosition(ticker: p.ticker, reason: "unsupported_asset_type"))
        }

        // 3. Resolve equity instruments
        for p in equityPositions {
            if let instrument = try await Instrument.query(on: db)
                .filter(\.$ticker == p.ticker)
                .join(Equity.self, on: \Equity.$id == \Instrument.$id)
                .first() {
                equityInstrumentIDs.append(instrument.id!)
            } else {
                logger.warning("[PortfolioActivity] dropping \(p.ticker): not_in_equities")
                droppedPositions.append(DroppedPosition(ticker: p.ticker, reason: "not_in_equities"))
            }
        }

        // 4. Resolve option instruments
        for p in optionPositions {
            guard let osiSymbol = p.osiSymbol else {
                logger.warning("[PortfolioActivity] dropping \(p.ticker): missing_osi_symbol")
                droppedPositions.append(DroppedPosition(ticker: p.ticker, reason: "missing_osi_symbol"))
                continue
            }

            // Parse OSI
            let osi: OSIComponents
            do {
                osi = try OSIParser.parse(osiSymbol)
            } catch {
                logger.warning("[PortfolioActivity] dropping \(osiSymbol): osi_parse_error (\(error))")
                droppedPositions.append(DroppedPosition(ticker: osiSymbol, reason: "osi_parse_error"))
                continue
            }

            // Look up underlying
            guard let underlying = try await Instrument.query(on: db)
                .filter(\.$ticker == osi.underlyingTicker)
                .join(Equity.self, on: \Equity.$id == \Instrument.$id)
                .first() else {
                logger.warning("[PortfolioActivity] dropping \(osiSymbol): underlying_not_in_equities")
                droppedPositions.append(DroppedPosition(ticker: osiSymbol, reason: "underlying_not_in_equities"))
                continue
            }

            // Check if contract already exists
            if let existing = try await OptionContract.query(on: db)
                .filter(\.$osiSymbol == osiSymbol)
                .first() {
                optionInstrumentIDs.append(existing.id!)
            } else {
                // Register new contract
                do {
                    let newID = try await OptionContractRegistrar.register(
                        osi: osi,
                        osiSymbol: osiSymbol,
                        underlyingInstrument: underlying,
                        db: db
                    )
                    optionInstrumentIDs.append(newID)
                    newContractsRegistered += 1
                } catch {
                    logger.error("[PortfolioActivity] failed to register \(osiSymbol): \(error)")
                }
            }
        }

        let duration = Date().timeIntervalSince(start)
        logger.info("[PortfolioActivity] complete in \(String(format: "%.2f", duration))s — equities=\(equityInstrumentIDs.count) options=\(optionInstrumentIDs.count) newContracts=\(newContractsRegistered) dropped=\(droppedPositions.count)")

        return FilteredPositionSet(
            equityInstrumentIDs: equityInstrumentIDs,
            optionInstrumentIDs: optionInstrumentIDs,
            newContractsRegistered: newContractsRegistered,
            droppedPositions: droppedPositions,
            runDate: runDate
        )
    }
}
