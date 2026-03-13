//
//  OptionContractRegistrar.swift
//  bug-free-memory
//
//  Idempotently registers a new Instrument + OptionContract pair
//  for a newly encountered option position.
//

import Fluent
import Foundation

enum OptionContractRegistrar {

    /// Registers a new option contract (Instrument + OptionContract) for the given OSI.
    /// Idempotent: if an Instrument with ticker == osiSymbol already exists, returns its id.
    /// - Returns: The UUID of the (existing or newly created) Instrument.
    static func register(
        osi: OSIComponents,
        osiSymbol: String,
        underlyingInstrument: Instrument,
        db: any Database
    ) async throws -> UUID {
        // 1. Check for existing instrument with this OSI symbol as ticker (idempotent re-entry)
        if let existing = try await Instrument.query(on: db)
            .filter(\.$ticker == osiSymbol)
            .first() {
            return existing.id!
        }

        // 2. Derive type, exercise style, and settlement from underlying
        let isIndex = underlyingInstrument.instrumentType == .index
        let instrumentType: InstrumentType = isIndex ? .indexOption : .equityOption
        let exerciseStyle: ExerciseStyle   = isIndex ? .european : .american
        let settlementType: String         = isIndex ? "cash" : "physical"

        // 3. Create and save Instrument
        let instrument = Instrument(
            instrumentType: instrumentType,
            ticker: osiSymbol,
            name: osiSymbol,
            exchangeID: underlyingInstrument.$exchange.id,
            currencyCode: underlyingInstrument.$currency.id,
            isActive: true
        )

        do {
            try await instrument.create(on: db)
        } catch {
            // Lost race — another task registered the same symbol; fetch and return it
            if let existing = try await Instrument.query(on: db)
                .filter(\.$ticker == osiSymbol)
                .first() {
                return existing.id!
            }
            throw error
        }

        // 4. Create and save OptionContract
        let contract = OptionContract(
            instrumentID: instrument.id!,
            underlyingID: underlyingInstrument.id!,
            optionType: osi.optionType,
            exerciseStyle: exerciseStyle,
            strikePrice: osi.strikePrice,
            expirationDate: osi.expirationDate,
            contractMultiplier: 100,
            settlementType: settlementType,
            osiSymbol: osiSymbol
        )
        try await contract.create(on: db)

        return instrument.id!
    }
}
