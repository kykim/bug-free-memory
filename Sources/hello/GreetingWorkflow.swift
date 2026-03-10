//
//  GreetingWorkflow.swift
//  hello
//
//  Created by Kevin Y Kim on 3/9/26.
//


import Temporal

@Workflow
final class GreetingWorkflow {
    func run(input: String) async throws -> String {
        let greeting = try await Workflow.executeActivity(
            GreetingActivities.Activities.SayHello.self,
            options: ActivityOptions(
                startToCloseTimeout: .seconds(30)
            ),
            input: input
        )

        return greeting
    }
}
