import Vapor
import ClerkVapor

extension Request {
    func requireDashboardAuth() throws {
        guard clerkAuth.isAuthenticated else { throw Abort.redirect(to: "/dashboard") }
    }

    func flash(_ msg: String, type: String, to path: String) -> Response {
        session.data["flash"] = msg
        session.data["flashType"] = type
        return redirect(to: path)
    }

    func popFlash() -> (message: String?, type: String?) {
        let message = session.data["flash"]
        let type = session.data["flashType"]
        session.data["flash"] = nil
        session.data["flashType"] = nil
        return (message, type)
    }
}

extension Optional where Wrapped == String {
    var ifNotEmpty: String? { self?.isEmpty == false ? self : nil }
}

extension Request {
    /// Runs Validatable checks on the request body, returning a flash redirect on failure.
    func validateContent<T: Validatable>(_ type: T.Type, redirectTo path: String) throws -> Response? {
        do {
            try T.validate(content: self)
            return nil
        } catch {
            return flash("Invalid input: \(error)", type: "error", to: path)
        }
    }
}

/// Parses a yyyy-MM-dd date string, throwing a 422 on failure.
func parseFormDate(_ string: String) throws -> Date {
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withFullDate]
    guard let date = fmt.date(from: string) else {
        throw AppError.invalidDateString(string)
    }
    return date
}
