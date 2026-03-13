//
//  DailyPipelineWorker.swift
//  bug-free-memory
//
//  Temporal worker for the daily options pipeline.
//  Task queue: daily-pipeline
//

import Fluent
import Logging
import Temporal
import TiingoKit
import Vapor

let dailyPipelineTaskQueue = "daily-pipeline"

func startDailyPipelineWorker(app: Application) async throws {
    // Build SchwabClient from environment
    guard let encryptionKey = app.tokenEncryptionKey else {
        app.logger.warning("[daily-pipeline-worker] TOKEN_ENCRYPTION_KEY not set — worker not starting")
        return
    }

    let schwabClient = SchwabClient(
        accountNumber: Environment.get("SCHWAB_ACCOUNT_NUMBER") ?? "",
        clientID:      Environment.get("SCHWAB_CLIENT_ID") ?? "",
        clientSecret:  Environment.get("SCHWAB_CLIENT_SECRET") ?? "",
        encryptionKey: encryptionKey
    )

    let worker = try TemporalWorker(
        configuration: .init(
            namespace: "default",
            taskQueue: dailyPipelineTaskQueue,
            instrumentation: .init(serverHostname: "temporal")
        ),
        target: .dns(host: "temporal", port: 7233),
        transportSecurity: .plaintext,
        activityContainers: [
            PortfolioActivities(db: app.db, schwabClient: schwabClient, logger: app.logger),
            EODPriceActivities(db: app.db, tiingoClient: app.tiingo, logger: app.logger),
            OptionEODPriceActivities(db: app.db, schwabClient: schwabClient, logger: app.logger),
            PricingActivities(db: app.db, logger: app.logger),
            RunLogActivities(db: app.db, logger: app.logger),
        ],
        workflows: [DailyPipelineWorkflow.self],
        logger: app.logger
    )

    try await worker.run()
}
