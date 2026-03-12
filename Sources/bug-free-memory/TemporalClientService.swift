//
//  TemporalClientService.swift
//  bug-free-memory
//
//  Starts the Temporal gRPC client connection on app boot so that
//  the web process can call startWorkflow without hanging.
//

import Vapor
import Logging

struct TemporalClientService: LifecycleHandler {
    let app: Application

    func didBoot(_ application: Application) throws {
        let logger = application.logger
        Task {
            do {
                try await application.temporal.run()
            } catch {
                logger.error("[temporal-client] connection ended: \(error)")
            }
        }
    }
}
