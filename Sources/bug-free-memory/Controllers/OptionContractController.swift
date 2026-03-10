import Fluent
import Leaf
import Vapor
import ClerkVapor

struct OptionContractController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("option-contracts")
        g.get(use: index); g.post(use: create)
        g.post(":id", "edit", use: update); g.post(":id", "delete", use: delete)
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()
        async let contracts   = OptionContract.query(on: req.db)
            .with(\.$instrument).with(\.$underlying)
            .sort(\.$expirationDate).all()
        async let underlyings = Instrument.query(on: req.db)
            .filter(.sql(unsafeRaw: "\"instrument_type\" IN ('equity'::instrument_type, 'index'::instrument_type)"))
            .sort(\.$ticker).all()
        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var contracts: [OptionContract]
            var underlyings: [Instrument]
            var flash: String?
            var flashType: String?
        }
        return try await req.clerkView("option-contracts", context: Context(contracts: contracts, underlyings: underlyings, flash: flash, flashType: flashType))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        struct Input: Content {
            var instrument_id: UUID; var underlying_id: UUID
            var option_type: String; var exercise_style: String
            var strike_price: Double; var expiration_date: String
            var contract_multiplier: Double?; var settlement_type: String?; var osi_symbol: String?
        }
        let input = try req.content.decode(Input.self)
        guard let optType = OptionType(rawValue: input.option_type),
              let exStyle = ExerciseStyle(rawValue: input.exercise_style) else {
            return req.flash("Invalid option type or exercise style.", type: "error", to: "/option-contracts")
        }
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        guard let expDate = fmt.date(from: input.expiration_date) else {
            return req.flash("Invalid expiration date format.", type: "error", to: "/option-contracts")
        }
        let contract = OptionContract(
            instrumentID: input.instrument_id, underlyingID: input.underlying_id,
            optionType: optType, exerciseStyle: exStyle,
            strikePrice: input.strike_price, expirationDate: expDate,
            contractMultiplier: input.contract_multiplier ?? 100,
            settlementType: input.settlement_type ?? "physical",
            osiSymbol: input.osi_symbol.ifNotEmpty
        )
        try await contract.save(on: req.db)
        return req.flash("Option contract created.", type: "success", to: "/option-contracts")
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let contract = try await OptionContract.find(id, on: req.db) else {
            return req.flash("Contract not found.", type: "error", to: "/option-contracts")
        }
        struct Input: Content {
            var strike_price: Double; var expiration_date: String
            var contract_multiplier: Double; var settlement_type: String; var osi_symbol: String?
        }
        let input = try req.content.decode(Input.self)
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        guard let expDate = fmt.date(from: input.expiration_date) else {
            return req.flash("Invalid expiration date format.", type: "error", to: "/option-contracts")
        }
        contract.strikePrice = input.strike_price; contract.expirationDate = expDate
        contract.contractMultiplier = input.contract_multiplier
        contract.settlementType = input.settlement_type
        contract.osiSymbol = input.osi_symbol.ifNotEmpty
        try await contract.save(on: req.db)
        return req.flash("Contract updated.", type: "success", to: "/option-contracts")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let contract = try await OptionContract.find(id, on: req.db) else {
            return req.flash("Contract not found.", type: "error", to: "/option-contracts")
        }
        try await contract.delete(on: req.db)
        return req.flash("Contract deleted.", type: "success", to: "/option-contracts")
    }
}
