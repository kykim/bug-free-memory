//
//  WorkerCommand.swift
//  bug-free-memory
//
//  Runs all Temporal activity and workflow workers.
//  Invoked via: `serve worker --env production`
//

import Vapor
import Temporal
import Logging

struct WorkerCommand: AsyncCommand {
    struct Signature: CommandSignature {}

    var help: String { "Runs all Temporal activity and workflow workers" }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let logger = app.logger

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withRetry(label: "option-pricing-worker", logger: logger) {
                    try await startOptionPricingWorker(app: app)
                }
            }
            group.addTask {
                await withRetry(label: "eod-price-worker", logger: logger) {
                    try await startEODPriceWorker(app: app)
                }
            }
            group.addTask {
                await withRetry(label: "fred-yield-worker", logger: logger) {
                    try await startFREDYieldWorker(app: app)
                }
            }
            group.addTask {
                await withRetry(label: "daily-pipeline-worker", logger: logger) {
                    try await startDailyPipelineWorker(app: app)
                }
            }
            group.addTask {
                await withRetry(label: "greeting-worker", logger: logger) {
                    let worker = try TemporalWorker(
                        configuration: .init(
                            namespace: "default",
                            taskQueue: "greeting-queue",
                            instrumentation: .init(serverHostname: "temporal")
                        ),
                        target: .dns(host: "temporal", port: 7233),
                        transportSecurity: .plaintext,
                        activityContainers: GreetingActivities(),
                        activities: [],
                        workflows: [GreetingWorkflow.self],
                        logger: logger
                    )
                    try await worker.run()
                }
            }
        }
    }
}

private func withRetry(
    label: String,
    logger: Logger,
    maxAttempts: Int = 10,
    delay: Duration = .seconds(3),
    operation: @escaping () async throws -> Void
) async {
    for attempt in 1...maxAttempts {
        do {
            try await operation()
            return
        } catch {
            if attempt < maxAttempts {
                logger.warning("[\(label)] attempt \(attempt) failed: \(error). Retrying in \(delay)...")
                try? await Task.sleep(for: delay)
            } else {
                logger.critical("[\(label)] failed after \(maxAttempts) attempts: \(error)")
            }
        }
    }
}
