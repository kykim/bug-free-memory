import Fluent
import Leaf
import Vapor
import ClerkVapor

struct FREDYieldController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("fred-yields")
        g.get(use: index)
        g.post("update", use: update)
    }

    func update(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        try await req.fredYieldService.triggerUpdate()
        return req.flash("FRED yield update started.", type: "success", to: "/fred-yields")
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()

        let selectedSeries = req.query[String.self, at: "series"].flatMap { FREDSeries(rawValue: $0) }
        let page = max(1, (req.query["page"] as Int?) ?? 1)
        let pageSize = 200

        var query = FREDYield.query(on: req.db)
        if let series = selectedSeries {
            query = query.filter(\.$seriesID == series)
        }
        let yields = try await query
            .sort(\.$observationDate, .descending)
            .range((page - 1) * pageSize ..< page * pageSize)
            .all()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        struct YieldRow: Encodable {
            var observationDate: String
            var seriesID: String
            var seriesLabel: String
            var yieldPercent: Double?
            var continuousRate: Double?
            var tenorYears: Double
            var source: String?
        }

        struct SeriesOption: Encodable {
            var value: String
            var label: String
            var selected: Bool
        }

        let yieldRows = yields.map { y in
            YieldRow(
                observationDate: df.string(from: y.observationDate),
                seriesID: y.seriesID.rawValue,
                seriesLabel: y.seriesID.label,
                yieldPercent: y.yieldPercent,
                continuousRate: y.continuousRate,
                tenorYears: y.tenorYears,
                source: y.source
            )
        }

        let seriesOptions = FREDSeries.allCases.map { s in
            SeriesOption(value: s.rawValue, label: "\(s.rawValue) — \(s.label)", selected: s == selectedSeries)
        }

        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var yields: [YieldRow]
            var seriesOptions: [SeriesOption]
            var selectedSeries: String?
            var page: Int
            var prevPage: Int
            var nextPage: Int
            var hasNextPage: Bool
            var flash: String?
            var flashType: String?
        }

        return try await req.clerkView("fred-yields", context: Context(
            yields: yieldRows,
            seriesOptions: seriesOptions,
            selectedSeries: selectedSeries?.rawValue,
            page: page,
            prevPage: page - 1,
            nextPage: page + 1,
            hasNextPage: yields.count == pageSize,
            flash: flash,
            flashType: flashType
        ))
    }
}
