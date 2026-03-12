import Temporal
import Vapor

/// Abstracts Temporal workflow interaction for FRED yield curve ingestion.
struct FREDYieldService {
    let temporal: TemporalClient
    let logger: Logger

    /// Triggers a yield curve update. Pass an ISO-8601 date string to fetch from
    /// that date forward; nil fetches the full FRED history.
    func triggerUpdate(observationStart: String? = nil) async throws {
        let workflowID = "update-fred-yields-\(UUID())"
        _ = try await temporal.startWorkflow(
            type: UpdateFREDYieldsWorkflow.self,
            options: .init(id: workflowID, taskQueue: "fred-yields"),
            input: UpdateFREDYieldsInput(observationStart: observationStart)
        )
        logger.info("[fred-yields] started update workflow \(workflowID)")
    }
}

extension Application {
    var fredYieldService: FREDYieldService {
        FREDYieldService(temporal: temporal, logger: logger)
    }
}

extension Request {
    var fredYieldService: FREDYieldService {
        application.fredYieldService
    }
}
