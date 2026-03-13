//
//  DailyPipelineWorkflowTests.swift
//  bug-free-memory
//
//  TICKET-015: DailyPipelineWorkflow tests.
//
//  DailyPipelineWorkflow orchestrates activities via Workflow.executeActivity,
//  which requires the Temporal runtime. Only the serialisable input type and
//  pure helper logic are unit-tested here; end-to-end orchestration is
//  covered by the smoke-test tickets (018–022).
//

import Testing
import Foundation
@testable import bug_free_memory

@Suite("DailyPipelineInput")
struct DailyPipelineInputTests {

    @Test("Codable round-trip preserves runDate")
    func codableRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_741_824_000) // 2025-03-13 00:00:00 UTC
        let input = DailyPipelineInput(runDate: date)
        let data = try JSONEncoder().encode(input)
        let decoded = try JSONDecoder().decode(DailyPipelineInput.self, from: data)
        #expect(abs(decoded.runDate.timeIntervalSince(date)) < 0.001)
    }
}
