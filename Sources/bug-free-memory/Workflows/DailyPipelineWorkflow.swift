//
//  DailyPipelineWorkflow.swift
//  bug-free-memory
//
//  Top-level Temporal workflow that orchestrates the daily options pipeline.
//  Short-circuits on market holidays. RunLogActivity always executes.
//

import Foundation
import Logging
import Temporal

public struct DailyPipelineInput: Codable, Sendable {
    public let runDate: Date
    /// Pre-computed by the schedule launcher; true when runDate is a recorded market holiday.
    public let isHoliday: Bool

    public init(runDate: Date, isHoliday: Bool = false) {
        self.runDate = runDate
        self.isHoliday = isHoliday
    }
}

@Workflow
public final class DailyPipelineWorkflow {

    public func run(input: DailyPipelineInput) async throws {
        let startedAt = Date()
        let runDate = input.runDate
        var errorMessages: [String] = []

        let runLogOptions = ActivityOptions(
            startToCloseTimeout: .seconds(60),
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(5),
                backoffCoefficient: 1.5,
                maximumAttempts: 5
            )
        )

        // 1. Short-circuit on market holiday or weekend
        if input.isHoliday || MarketCalendar.isWeekend(runDate) {
            let skipInput = RunLogInput(
                runDate: runDate,
                status: .skipped,
                portfolioResult: nil,
                eodResult: nil,
                indexEODResult: nil,
                optionEODResult: nil,
                pricingResult: nil,
                errorMessages: [input.isHoliday ? "Market holiday — pipeline skipped" : "Weekend — pipeline skipped"],
                startedAt: startedAt,
                completedAt: Date()
            )
            try await Workflow.executeActivity(
                RunLogActivities.Activities.WriteRunLog.self,
                options: runLogOptions,
                input: skipInput
            )
            return
        }

        let portfolioOptions = ActivityOptions(
            scheduleToCloseTimeout: .seconds(300),
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(30),
                backoffCoefficient: 2.0,
                maximumAttempts: 3
            )
        )
        let eodOptions = ActivityOptions(
            scheduleToCloseTimeout: .seconds(300),
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(30),
                backoffCoefficient: 2.0,
                maximumAttempts: 3
            )
        )
        let optionEODOptions = ActivityOptions(
            scheduleToCloseTimeout: .seconds(600),
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(30),
                backoffCoefficient: 2.0,
                maximumAttempts: 3
            )
        )
        let pricingOptions = ActivityOptions(
            scheduleToCloseTimeout: .seconds(1800),
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(10),
                backoffCoefficient: 1.5,
                maximumAttempts: 2
            )
        )

        // 2. Portfolio activity
        var portfolioResult: FilteredPositionSet?
        do {
            portfolioResult = try await Workflow.executeActivity(
                PortfolioActivities.Activities.FetchPortfolioPositions.self,
                options: portfolioOptions,
                input: runDate
            )
        } catch {
            errorMessages.append("PortfolioActivity failed: \(error)")
        }

        // 3. EOD price activity (equities — Tiingo)
        var eodResult: EODPriceResult?
        do {
            eodResult = try await Workflow.executeActivity(
                EODPriceActivities.Activities.FetchAndUpsertEODPrices.self,
                options: eodOptions,
                input: runDate
            )
        } catch {
            errorMessages.append("EODPriceActivity failed: \(error)")
        }

        // 4. Index EOD price activity (Schwab)
        var indexEODResult: EODPriceResult?
        do {
            indexEODResult = try await Workflow.executeActivity(
                IndexEODPriceActivities.Activities.FetchAndUpsertEODIndexPrices.self,
                options: eodOptions,
                input: runDate
            )
        } catch {
            errorMessages.append("IndexEODPriceActivity failed: \(error)")
        }

        // 5. Option EOD price activity
        var optionEODResult: OptionEODResult?
        do {
            optionEODResult = try await Workflow.executeActivity(
                OptionEODPriceActivities.Activities.FetchAndUpsertOptionEODPrices.self,
                options: optionEODOptions,
                input: runDate
            )
        } catch {
            errorMessages.append("OptionEODPriceActivity failed: \(error)")
        }

        // 6. Pricing activity — only if option EOD data was fetched
        var pricingResult: PricingResult?
        if (optionEODResult?.rowsUpserted ?? 0) > 0 {
            do {
                pricingResult = try await Workflow.executeActivity(
                    PricingActivities.Activities.PriceAllContracts.self,
                    options: pricingOptions,
                    input: runDate
                )
            } catch {
                errorMessages.append("PricingActivity failed: \(error)")
            }
        } else {
            errorMessages.append("PricingActivity skipped: no option EOD data")
        }

        // 7. Determine status
        let status = RunStatus.determine(
            portfolioResult: portfolioResult,
            eodResult: eodResult,
            optionEODResult: optionEODResult,
            pricingResult: pricingResult,
            errorMessages: errorMessages
        )

        // 8. RunLogActivity — always executes
        let logInput = RunLogInput(
            runDate: runDate,
            status: status,
            portfolioResult: portfolioResult,
            eodResult: eodResult,
            indexEODResult: indexEODResult,
            optionEODResult: optionEODResult,
            pricingResult: pricingResult,
            errorMessages: errorMessages,
            startedAt: startedAt,
            completedAt: Date()
        )
        try await Workflow.executeActivity(
            RunLogActivities.Activities.WriteRunLog.self,
            options: runLogOptions,
            input: logInput
        )
    }
}
