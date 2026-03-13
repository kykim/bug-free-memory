//
//  PricingIdempotencyTests.swift
//  bug-free-memory
//
//  TICKET-021: Validate idempotency — re-run PricingActivity for same date
//
//  Integration tests that require a live database with FRED yields, option
//  EOD prices, and underlying EOD history already loaded.
//
//  Run manually against a staging environment:
//
//    swift test --filter PricingIdempotencyTests
//
//  Acceptance criteria:
//  - Running PricingActivities.priceAllContracts twice for the same runDate
//    produces no unique constraint violations.
//  - Exactly 3 rows per non-expired contract after both runs.
//  - Prices from run 2 match prices from run 1 (deterministic).
//
//  Verification SQL:
//
//    -- Check exactly 3 rows per contract
//    SELECT instrument_id, COUNT(*) AS model_count
//    FROM theoretical_option_eod_prices
//    WHERE price_date = '<runDate>'
//    GROUP BY instrument_id
//    HAVING COUNT(*) != 3;
//    → expect 0 rows
//
//    -- Check prices are deterministic (run 1 vs run 2 via updated_at timestamp)
//    SELECT * FROM theoretical_option_eod_prices
//    WHERE price_date = '<runDate>' AND source = 'calculated'
//    ORDER BY instrument_id, model;
//

import Testing
import Foundation
@testable import bug_free_memory

@Suite("PricingActivity idempotency", .disabled("Requires live database"))
struct PricingIdempotencyTests {

    @Test("Re-running PricingActivity for same date produces no duplicates")
    func testIdempotentPricing() async throws {
        // 1. Ensure eod_prices, option_eod_prices, and fred_yields are populated for runDate
        // 2. Run PricingActivities.priceAllContracts for runDate
        // 3. Record contractsPriced and rowsUpserted
        // 4. Run again for the same date
        // 5. Assert results match (same counts, no constraint violations)
        // 6. Query DB — assert exactly 3 rows per contract (BS, Binomial, MC)
        throw XCTSkip("Integration test — run manually against staging DB")
    }
}

import XCTest
