//
//  EODPriceIdempotencyTests.swift
//  bug-free-memory
//
//  TICKET-020: Validate idempotency — re-run EODPriceActivity for same date
//
//  These are integration tests that require a live database and Tiingo credentials.
//  Run manually against a staging environment:
//
//    swift test --filter EODPriceIdempotencyTests
//
//  Acceptance criteria:
//  - Running EODPriceActivities.fetchAndUpsertEODPrices twice for the same runDate
//    produces no unique constraint violations.
//  - Row count in eod_prices is unchanged between run 1 and run 2.
//  - rowsUpserted count is identical in both runs.
//

import Testing
import Foundation
@testable import bug_free_memory

// Integration tests are skipped by default (require live DB + Tiingo key).
// Remove the `@disabled` annotation and set up DB before running.
@Suite("EODPriceActivity idempotency", .disabled("Requires live database"))
struct EODPriceIdempotencyTests {

    // MARK: - Placeholder

    @Test("Re-running EODPriceActivity for same date produces no duplicate rows")
    func testIdempotentUpsert() async throws {
        // 1. Obtain a database connection (configure in test setup)
        // 2. Run the activity for a known past trading day
        // 3. Record rowsUpserted from run 1
        // 4. Run again for the same date
        // 5. Assert rowsUpserted matches run 1
        // 6. Query eod_prices directly — assert no duplicates for (instrument_id, price_date)
        //    SELECT instrument_id, price_date, COUNT(*) FROM eod_prices
        //    WHERE price_date = '<runDate>'
        //    GROUP BY instrument_id, price_date
        //    HAVING COUNT(*) > 1;
        //    → expect 0 rows
        throw XCTSkip("Integration test — run manually against staging DB")
    }
}

// Required to compile XCTSkip reference
import XCTest
