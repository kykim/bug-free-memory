import Foundation
import Temporal
import Vapor

/// Abstracts Temporal workflow interaction for EOD price ingestion.
struct EODPriceService {
    let temporal: TemporalClient
    let logger: Logger

    /// Triggers a historical backfill from `startDate` to `endDate` (nil = today).
    func backfill(equityID: UUID, ticker: String, from startDate: Date, to endDate: Date? = nil) async throws {
        let workflowID = "backfill-\(equityID)-\(UUID())"
        _ = try await temporal.startWorkflow(
            type: UpdateEODPricesWorkflow.self,
            options: .init(id: workflowID, taskQueue: "eod-prices"),
            input: UpdateEODPricesInput(equityID: equityID, ticker: ticker, startDate: startDate, endDate: endDate)
        )
        logger.info("[eod-prices] started backfill workflow \(workflowID) for \(ticker)")
    }

    /// Triggers a fetch for a specific date's EOD price only.
    func fetchToday(equityID: UUID, ticker: String, date: Date) async throws {
        let workflowID = "fetch-today-\(equityID)-\(UUID())"
        _ = try await temporal.startWorkflow(
            type: UpdateEODPricesWorkflow.self,
            options: .init(id: workflowID, taskQueue: "eod-prices"),
            input: UpdateEODPricesInput(equityID: equityID, ticker: ticker, startDate: date, endDate: date)
        )
        logger.info("[eod-prices] started fetch-today workflow \(workflowID) for \(ticker)")
    }
}

extension Application {
    var eodPriceService: EODPriceService {
        EODPriceService(temporal: temporal, logger: logger)
    }
}

extension Request {
    var eodPriceService: EODPriceService {
        application.eodPriceService
    }
}
