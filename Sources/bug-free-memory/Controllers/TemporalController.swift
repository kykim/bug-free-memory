import Foundation
import Logging
import Temporal
import Vapor
import ClerkVapor

struct TemporalController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("temporal")
        g.post("register-schedule", use: registerSchedule)
    }

    func registerSchedule(req: Request) async throws -> Response {
        try req.requireDashboardAuth()

        let logger = req.logger
        let scheduleID = "daily-pipeline-schedule"

        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd"
        fmt.timeZone = TimeZone(identifier: "America/New_York")
        fmt.locale = Locale(identifier: "en_US_POSIX")
        let todayStr = fmt.string(from: Date())

        do {
            let client = try TemporalClient(
                target: .dns(host: "temporal", port: 7233),
                transportSecurity: .plaintext,
                configuration: .init(instrumentation: .init(serverHostname: "temporal")),
                logger: logger
            )

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await client.run() }
                try await Task.sleep(for: .milliseconds(500))

                let calendarSpec = ScheduleCalendarSpecification(
                    minute:    [ScheduleRange(value: 0)],
                    hour:      [ScheduleRange(value: 16)],
                    dayOfWeek: [
                        ScheduleRange(value: 1),
                        ScheduleRange(value: 2),
                        ScheduleRange(value: 3),
                        ScheduleRange(value: 4),
                        ScheduleRange(value: 5),
                    ]
                )

                let schedule = Schedule(
                    action: .startWorkflow(.init(
                        workflowName: "\(DailyPipelineWorkflow.self)",
                        options: .init(id: "daily-pipeline-\(todayStr)", taskQueue: dailyPipelineTaskQueue),
                        input: DailyPipelineInput(runDate: Date())
                    )),
                    specification: ScheduleSpecification(
                        calendars: [calendarSpec],
                        timeZoneName: "America/New_York"
                    )
                )

                do {
                    _ = try await client.createSchedule(id: scheduleID, schedule: schedule)
                    logger.info("[TemporalController] schedule '\(scheduleID)' created")
                } catch {
                    let desc = String(describing: error)
                    if desc.contains("ALREADY_EXISTS") || desc.contains("already exists") {
                        logger.info("[TemporalController] schedule '\(scheduleID)' already exists")
                    } else {
                        throw error
                    }
                }

                group.cancelAll()
            }
        } catch {
            return req.flash("Failed to register schedule: \(error)", type: "error", to: "/dashboard")
        }

        return req.flash("Schedule '\(scheduleID)' registered (or already existed).", type: "success", to: "/dashboard")
    }
}
