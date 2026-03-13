import Fluent
import Leaf
import Vapor
import ClerkVapor

struct MarketHolidayController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("market-holidays")
        g.get(use: index)
        g.post(use: create)
        g.post(":id", "delete", use: delete)
    }

    func index(req: Request) async throws -> View {
        try req.requireDashboardAuth()

        let page = max(1, (req.query["page"] as Int?) ?? 1)
        let pageSize = 100

        let holidays = try await MarketHoliday.query(on: req.db)
            .sort(\.$holidayDate, .descending)
            .range((page - 1) * pageSize ..< page * pageSize)
            .all()

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        struct HolidayRow: Encodable {
            var id: String
            var holidayDate: String
            var description: String?
        }

        let rows = holidays.map { h in
            HolidayRow(
                id: h.id!.uuidString,
                holidayDate: df.string(from: h.holidayDate),
                description: h.description
            )
        }

        let (flash, flashType) = req.popFlash()
        struct Context: Encodable {
            var holidays: [HolidayRow]
            var page: Int
            var prevPage: Int
            var nextPage: Int
            var hasNextPage: Bool
            var flash: String?
            var flashType: String?
        }

        return try await req.clerkView("market-holidays", context: Context(
            holidays: rows,
            page: page,
            prevPage: page - 1,
            nextPage: page + 1,
            hasNextPage: rows.count == pageSize,
            flash: flash,
            flashType: flashType
        ))
    }

    func create(req: Request) async throws -> Response {
        try req.requireDashboardAuth()

        struct Input: Content {
            var holidayDate: String
            var description: String?
        }
        let input = try req.content.decode(Input.self)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(identifier: "UTC")

        guard let date = df.date(from: input.holidayDate) else {
            return req.flash("Invalid date format. Use YYYY-MM-DD.", type: "error", to: "/market-holidays")
        }

        do {
            try await MarketCalendar.addHoliday(date, description: input.description?.isEmpty == true ? nil : input.description, db: req.db)
        } catch {
            return req.flash("Holiday already exists for that date.", type: "error", to: "/market-holidays")
        }

        return req.flash("Holiday added.", type: "success", to: "/market-holidays")
    }

    func delete(req: Request) async throws -> Response {
        try req.requireDashboardAuth()
        guard let id = req.parameters.get("id", as: UUID.self),
              let holiday = try await MarketHoliday.find(id, on: req.db) else {
            return req.flash("Holiday not found.", type: "error", to: "/market-holidays")
        }
        try await holiday.delete(on: req.db)
        return req.flash("Holiday deleted.", type: "success", to: "/market-holidays")
    }
}
