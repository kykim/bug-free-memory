//
//  UpsertEODPricesActivities.swift
//  hello
//
//  Created by Kevin Y Kim on 3/10/26.
//

// Temporal/Activities/UpsertEODPricesActivity.swift
import Foundation
import Fluent
import Temporal

@ActivityContainer
public struct UpsertEODPricesActivities {

    private let db: any Database

    public init(db: any Database) {
        self.db = db
    }

    /// Upserts a batch of EOD prices into the database.
    /// Returns the number of records inserted or updated.
    @Activity
    public func upsertEODPrices(fetched: FetchedEODPrices) async throws -> Int {
        var upsertCount = 0

        for record in fetched.prices {
            // Normalize to midnight UTC so duplicate checks are date-only
            let priceDate = Calendar.utc.startOfDay(for: record.date)

            let existing = try await EODPrice.query(on: db)
                .filter(\.$instrument.$id == fetched.equityID)
                .filter(\.$priceDate == priceDate)
                .first()

            if let existing {
                existing.open     = record.open
                existing.high     = record.high
                existing.low      = record.low
                existing.close    = record.close
                existing.adjClose = record.adjClose
                existing.volume   = record.volume
                existing.source   = "tiingo"
                try await existing.save(on: db)
            } else {
                let price = EODPrice()
                price.$instrument.id = fetched.equityID
                price.priceDate   = priceDate
                price.open        = record.open
                price.high        = record.high
                price.low         = record.low
                price.close       = record.close
                price.adjClose    = record.adjClose
                price.volume      = record.volume
                price.source      = "tiingo"
                try await price.create(on: db)
            }

            upsertCount += 1
        }

        return upsertCount
    }
}

