import Leaf
import Vapor
import ClerkVapor

struct SchwabController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let g = routes.grouped(ClerkMiddleware()).grouped("schwab")
        g.get("portfolio", use: portfolio)
    }

    func portfolio(req: Request) async throws -> View {
        try req.requireDashboardAuth()

        struct Context: Encodable {
            var portfolioJSON: String?
            var error: String?
        }

        guard let schwabClient = req.application.schwab else {
            return try await req.clerkView("schwab-portfolio", context: Context(
                portfolioJSON: nil,
                error: "Schwab client not configured (TOKEN_ENCRYPTION_KEY missing)."
            ))
        }

        do {
            try await schwabClient.refreshTokenIfNeeded(db: req.db)
            let positions = try await schwabClient.fetchPortfolioPositions()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let json = String(data: try encoder.encode(positions), encoding: .utf8) ?? "[]"
            return try await req.clerkView("schwab-portfolio", context: Context(portfolioJSON: json, error: nil))
        } catch SchwabError.noTokenFound {
            return try await req.clerkView("schwab-portfolio", context: Context(
                portfolioJSON: nil,
                error: "No Schwab account connected. Please connect your Schwab account from the Dashboard."
            ))
        } catch SchwabError.authFailure {
            return try await req.clerkView("schwab-portfolio", context: Context(
                portfolioJSON: nil,
                error: "Schwab authentication failed. Please reconnect your account from the Dashboard."
            ))
        } catch {
            return try await req.clerkView("schwab-portfolio", context: Context(
                portfolioJSON: nil,
                error: "Schwab error: \(error)"
            ))
        }
    }
}
