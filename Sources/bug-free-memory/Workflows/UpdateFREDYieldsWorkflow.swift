//
//  UpdateFREDYieldsWorkflow.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//

import Foundation
import Temporal

public struct UpdateFREDYieldsResult: Codable, Sendable {
    public let totalRecordsUpserted: Int
}

@Workflow
public final class UpdateFREDYieldsWorkflow {

    public func run(input: UpdateFREDYieldsInput) async throws -> UpdateFREDYieldsResult {
        let options = ActivityOptions(
            startToCloseTimeout: .seconds(120),
            retryPolicy: RetryPolicy(
                initialInterval: .seconds(5),
                backoffCoefficient: 2.0,
                maximumInterval: .seconds(60),
                maximumAttempts: 3
            )
        )

        let r1 = try await Workflow.executeActivity(
            UpdateFREDYieldsActivities.Activities.FetchAndUpsertOneMonth.self,
            options: options, input: input
        )
        let r2 = try await Workflow.executeActivity(
            UpdateFREDYieldsActivities.Activities.FetchAndUpsertThreeMonth.self,
            options: options, input: input
        )
        let r3 = try await Workflow.executeActivity(
            UpdateFREDYieldsActivities.Activities.FetchAndUpsertSixMonth.self,
            options: options, input: input
        )
        let r4 = try await Workflow.executeActivity(
            UpdateFREDYieldsActivities.Activities.FetchAndUpsertOneYear.self,
            options: options, input: input
        )
        let r5 = try await Workflow.executeActivity(
            UpdateFREDYieldsActivities.Activities.FetchAndUpsertTwoYear.self,
            options: options, input: input
        )
        let r6 = try await Workflow.executeActivity(
            UpdateFREDYieldsActivities.Activities.FetchAndUpsertFiveYear.self,
            options: options, input: input
        )

        return UpdateFREDYieldsResult(totalRecordsUpserted: r1 + r2 + r3 + r4 + r5 + r6)
    }
}
