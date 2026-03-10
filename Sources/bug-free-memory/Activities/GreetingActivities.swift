//
//  GreetingActivities.swift
//  hello
//
//  Created by Kevin Y Kim on 3/9/26.
//


import Temporal

@ActivityContainer
struct GreetingActivities {
    @Activity
    func sayHello(input: String) -> String {
        "Hello, \(input)!"
    }
}
