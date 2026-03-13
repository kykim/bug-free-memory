//
//  RegisterScheduleCommand.swift
//  bug-free-memory
//
//  One-time setup command that registers the daily pipeline cron schedule
//  in Temporal. Running it a second time is safe — ALREADY_EXISTS is caught.
//
//  Usage: vapor run register-schedule --env production
//
//  Schedule spec: 0 16 * * 1-5  (4:00 PM ET, Monday–Friday)
//  Schedule ID:   "daily-pipeline-schedule"
//  Workflow ID:   "daily-pipeline-YYYYMMDD" (per execution)
//

import Foundation
import Logging
import Temporal
import Vapor

struct RegisterScheduleCommand: AsyncCommand {
    struct Signature: CommandSignature {}

    var help: String {
        "Registers the daily-pipeline Temporal schedule (idempotent)"
    }

    private static let scheduleID = "daily-pipeline-schedule"

    private static let workflowIDDateFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        return fmt
    }()

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let logger = app.logger

        let client = try TemporalClient(
            target: .dns(host: "temporal", port: 7233),
            transportSecurity: .plaintext,
            configuration: .init(
                instrumentation: .init(serverHostname: "temporal")
            ),
            logger: logger
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await client.run() }

            // Wait briefly for the client to connect
            try await Task.sleep(for: .milliseconds(500))

            let todayStr = Self.workflowIDDateFormatter.string(from: Date())

            // Calendar spec: 4 PM ET, weekdays only (Mon–Fri)
            let calendarSpec = Schedule.SpecCalendar(
                minute:     [.init(value: 0)],
                hour:       [.init(value: 16)],
                dayOfWeek:  [
                    .init(value: 1), // Monday
                    .init(value: 2), // Tuesday
                    .init(value: 3), // Wednesday
                    .init(value: 4), // Thursday
                    .init(value: 5), // Friday
                ]
            )

            let schedule = Schedule(
                action: .startWorkflow(
                    .init(
                        workflowName: "\(DailyPipelineWorkflow.self)",
                        options: .init(
                            id: "daily-pipeline-\(todayStr)",
                            taskQueue: dailyPipelineTaskQueue
                        ),
                        input: DailyPipelineInput(runDate: Date())
                    )
                ),
                specification: .init(
                    calendars: [calendarSpec],
                    timeZoneName: "America/New_York"
                )
            )

            do {
                _ = try await client.createSchedule(
                    id: Self.scheduleID,
                    schedule: schedule
                )
                logger.info("[RegisterSchedule] schedule '\(Self.scheduleID)' created successfully")
            } catch {
                let description = String(describing: error)
                if description.contains("ALREADY_EXISTS") || description.contains("already exists") {
                    logger.info("[RegisterSchedule] schedule '\(Self.scheduleID)' already exists — nothing to do")
                } else {
                    logger.error("[RegisterSchedule] failed to create schedule: \(error)")
                    throw error
                }
            }

            group.cancelAll()
        }
    }
}
