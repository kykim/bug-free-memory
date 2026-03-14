//
//  OptionPricingWorker.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Fluent
import Temporal
import Vapor

func startOptionPricingWorker(app: Application) async throws {
    let worker = try TemporalWorker(
        configuration: .init(
            namespace: "default",
            taskQueue: "option-pricing",
            instrumentation: .init(serverHostname: "temporal")
        ),
        target: .dns(host: "temporal", port: 7233),
        transportSecurity: .plaintext,
        activityContainers: PriceOptionContractActivities(db: app.db, logger: app.logger),
        workflows: [PriceOptionContractWorkflow.self, ComputeMonteCarloGreeksWorkflow.self],
        logger: app.logger
    )

    try await worker.run()
}
