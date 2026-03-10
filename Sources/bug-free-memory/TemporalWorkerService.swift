//
//  TemporalWorkerService.swift
//  hello
//
//  Created by Kevin Y Kim on 3/9/26.
//

import Vapor
import Temporal
import Logging

struct TemporalWorkerService: LifecycleHandler {
    let app: Application

    func didBoot(_ application: Application) throws {
        let logger = Logger(label: "com.example.temporal.worker")
        
        Task {
            do {
                application.logger.info("Starting Temporal client...")
                try await application.temporal.run()
            } catch {
                application.logger.error("Temporal client failed: \(error)")
            }
        }

        let namespace = "default"
        let taskQueue = "greeting-queue"

        Task {
            do {
                application.logger.info("Starting Temporal worker...")
                let workerConfiguration = TemporalWorker.Configuration(
                    namespace: namespace,
                    taskQueue: taskQueue,
                    instrumentation: .init(serverHostname: "temporal")
                )

                let worker = try TemporalWorker(
                    configuration: workerConfiguration,
                    target: .dns(host: "temporal", port: 7233),
                    transportSecurity: .plaintext,
                    activityContainers: GreetingActivities(),
                    activities: [],
                    workflows: [GreetingWorkflow.self],
                    logger: logger
                )
                
                application.logger.info("Temporal worker created, running...")
                try await worker.run()
            } catch {
                application.logger.error("Temporal worker failed: \(error)")
            }
        }
        
        Task {
            do {
                application.logger.info("Starting Temporal worker startEODPriceWorker...")
                try await startEODPriceWorker(app: application)
            } catch {
                app.logger.critical("EOD price worker failed: \(error)")
            }
        }
    }
}
