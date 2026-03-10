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
