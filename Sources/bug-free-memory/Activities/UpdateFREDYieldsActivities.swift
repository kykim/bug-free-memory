//
//  UpdateFREDYieldsActivities.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/11/26.
//
//  Six activities — one per FREDSeries — that fetch observations from the
//  FRED API and upsert them into the fred_yields table.
//

import AsyncHTTPClient
import Foundation
import Fluent
import NIOFoundationCompat
import Temporal

// MARK: - Input / Output

public struct UpdateFREDYieldsInput: Codable, Sendable {
    /// Inclusive start date in "yyyy-MM-dd" format. Nil → FRED default (full history).
    public let observationStart: String?

    public init(observationStart: String? = nil) {
        self.observationStart = observationStart
    }
}

// MARK: - FRED API response types

private struct FREDObservationResponse: Decodable {
    let observations: [FREDObservation]
}

private struct FREDObservation: Decodable {
    let date: String
    let value: String
}

// MARK: - Activity Container

@ActivityContainer
public struct UpdateFREDYieldsActivities {

    private let db: any Database
    private let apiKey: String
    private let httpClient: HTTPClient

    public init(db: any Database, apiKey: String, httpClient: HTTPClient) {
        self.db = db
        self.apiKey = apiKey
        self.httpClient = httpClient
    }

    @Activity
    public func fetchAndUpsertOneMonth(input: UpdateFREDYieldsInput) async throws -> Int {
        try await fetchAndUpsert(series: .oneMonth, input: input)
    }

    @Activity
    public func fetchAndUpsertThreeMonth(input: UpdateFREDYieldsInput) async throws -> Int {
        try await fetchAndUpsert(series: .threeMonth, input: input)
    }

    @Activity
    public func fetchAndUpsertSixMonth(input: UpdateFREDYieldsInput) async throws -> Int {
        try await fetchAndUpsert(series: .sixMonth, input: input)
    }

    @Activity
    public func fetchAndUpsertOneYear(input: UpdateFREDYieldsInput) async throws -> Int {
        try await fetchAndUpsert(series: .oneYear, input: input)
    }

    @Activity
    public func fetchAndUpsertTwoYear(input: UpdateFREDYieldsInput) async throws -> Int {
        try await fetchAndUpsert(series: .twoYear, input: input)
    }

    @Activity
    public func fetchAndUpsertFiveYear(input: UpdateFREDYieldsInput) async throws -> Int {
        try await fetchAndUpsert(series: .fiveYear, input: input)
    }

    // MARK: - Shared helpers

    private func fetchAndUpsert(series: FREDSeries, input: UpdateFREDYieldsInput) async throws -> Int {
        let observations = try await fetchFromFRED(series: series, observationStart: input.observationStart)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        var upsertCount = 0
        for obs in observations {
            guard let date = df.date(from: obs.date) else { continue }
            let yieldPercent = Double(obs.value)  // nil when value == "."

            let existing = try await FREDYield.query(on: db)
                .filter(\.$seriesID == series)
                .filter(\.$observationDate == date)
                .first()

            if let existing {
                existing.yieldPercent  = yieldPercent
                existing.continuousRate = yieldPercent.map { log(1 + $0 / 100) }
                try await existing.save(on: db)
            } else {
                let record = FREDYield(
                    seriesID: series,
                    observationDate: date,
                    yieldPercent: yieldPercent,
                    source: "FRED"
                )
                try await record.create(on: db)
            }
            upsertCount += 1
        }
        return upsertCount
    }

    private func fetchFromFRED(series: FREDSeries, observationStart: String?) async throws -> [FREDObservation] {
        var components = URLComponents(string: "https://api.stlouisfed.org/fred/series/observations")!
        var queryItems: [URLQueryItem] = [
            .init(name: "series_id",  value: series.rawValue),
            .init(name: "api_key",    value: apiKey),
            .init(name: "file_type",  value: "json"),
            .init(name: "sort_order", value: "asc"),
        ]
        if let start = observationStart {
            queryItems.append(.init(name: "observation_start", value: start))
        }
        components.queryItems = queryItems

        let request = HTTPClientRequest(url: components.url!.absoluteString)
        let response = try await httpClient.execute(request, timeout: .seconds(60))
        let body = try await response.body.collect(upTo: 20 * 1024 * 1024)
        let data = Data(buffer: body)
        let decoded = try JSONDecoder().decode(FREDObservationResponse.self, from: data)
        return decoded.observations
    }
}
