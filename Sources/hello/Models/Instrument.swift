import Fluent
import Vapor

enum InstrumentType: String, Codable {
    case equity
    case index
    case equityOption = "equity_option"
    case indexOption  = "index_option"
}

final class Instrument: Model, Content, @unchecked Sendable {
    static let schema = "instruments"

    @ID(custom: "instrument_id", generatedBy: .database)
    var id: Int?

    @Enum(key: "instrument_type")
    var instrumentType: InstrumentType

    @Field(key: "ticker")
    var ticker: String

    @Field(key: "name")
    var name: String

    @OptionalParent(key: "exchange_id")
    var exchange: Exchange?

    @Parent(key: "currency_code")
    var currency: Currency

    @Field(key: "is_active")
    var isActive: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    // Relations
    @OptionalChild(for: \.$instrument)
    var equity: Equity?

    @OptionalChild(for: \.$instrument)
    var index: Index?

    @OptionalChild(for: \.$instrument)
    var optionContract: OptionContract?

    @Children(for: \.$instrument)
    var eodPrices: [EODPrice]

    @Children(for: \.$instrument)
    var optionEODPrices: [OptionEODPrice]

    @Children(for: \.$instrument)
    var corporateActions: [CorporateAction]

    init() {}

    init(
        id: Int? = nil,
        instrumentType: InstrumentType,
        ticker: String,
        name: String,
        exchangeID: Int? = nil,
        currencyCode: String,
        isActive: Bool = true
    ) {
        self.id = id
        self.instrumentType = instrumentType
        self.ticker = ticker
        self.name = name
        self.$exchange.id = exchangeID
        self.$currency.id = currencyCode
        self.isActive = isActive
    }

    // Plain accessors for Leaf templates (which can't use $ property wrapper syntax)
    var exchangeID: Int?   { $exchange.id }
    var currencyCode: String { $currency.id }
}
