//
//  FREDYieldWorker.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Fluent
import Temporal
import Vapor

func startFREDYieldWorker(app: Application) async throws {
    let worker = try TemporalWorker(
        configuration: .init(
            namespace: "default",
            taskQueue: "fred-yields",
            instrumentation: .init(serverHostname: "temporal")
        ),
        target: .dns(host: "temporal", port: 7233),
        transportSecurity: .plaintext,
        activityContainers: UpdateFREDYieldsActivities(
            db: app.db,
            apiKey: Environment.get("FRED_API_KEY") ?? "",
            httpClient: app.http.client.shared
        ),
        workflows: [UpdateFREDYieldsWorkflow.self],
        logger: app.logger
    )

    try await worker.run()
}
