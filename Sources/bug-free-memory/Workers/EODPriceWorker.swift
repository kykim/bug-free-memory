//
//  EODPriceWorker.swift
//  hello
//
//  Created by Kevin Y Kim on 3/10/26.
//

import Fluent
import Temporal
import Vapor

func startEODPriceWorker(app: Application) async throws {
    let worker = try TemporalWorker(
        configuration: .init(
            namespace: "default",
            taskQueue: "eod-prices",
            instrumentation: .init(serverHostname: "temporal")
        ),
        target: .dns(host: "temporal", port: 7233),
        transportSecurity: .plaintext,
        activityContainers:
            FetchTiingoPricesActivities(tiingo: app.tiingo),
            UpsertEODPricesActivities(db: app.db),
        workflows: [UpdateEODPricesWorkflow.self],
        logger: app.logger
    )

    try await worker.run()
}
