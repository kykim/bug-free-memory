import VaporTesting
import Vapor
import Testing

@Suite("App Tests")
struct bug_free_memoryTests {
    @Test("Test Hello World Route")
    func helloWorld() async throws {
        try await withApp(configure: { app in
            app.get("hello") { _ in "Hello, world!" }
        }) { app in
            try await app.testing().test(.GET, "hello", afterResponse: { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "Hello, world!")
            })
        }
    }
}
