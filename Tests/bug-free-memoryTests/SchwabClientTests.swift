//
//  SchwabClientTests.swift
//  bug-free-memory
//
//  TICKET-008: SchwabClient + SchwabClient+Portfolio tests.
//  Network tests intercept URLSession.shared via MockURLProtocol.
//  DB tests use in-memory SQLite.
//

import Testing
import Foundation
import Crypto
import Fluent
import FluentSQLiteDriver
import VaporTesting
@testable import bug_free_memory

// MARK: - MockURLProtocol

/// Intercepts all URLSession.shared requests for the duration of a test.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Data, HTTPURLResponse))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (data, response) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private func mockResponse(statusCode: Int, body: String = "{}",
                          url: URL = URL(string: "https://api.schwabapi.com")!) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
}

// MARK: - Helpers

private func makeClient(accountNumber: String = "ACC123", session: URLSession = .shared) -> SchwabClient {
    let key = SymmetricKey(size: .bits256)
    return SchwabClient(
        accountNumber: accountNumber,
        clientID: "cid",
        clientSecret: "csecret",
        encryptionKey: key,
        accessToken: "test-token",
        session: session
    )
}

private func makeMockSession(handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) -> URLSession {
    MockURLProtocol.handler = handler
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

private func withOAuthDB(_ body: (any Database) async throws -> Void) async throws {
    try await withApp(configure: { app in
        app.databases.use(.sqlite(.memory), as: .sqlite)
        app.migrations.add(CreateOAuthToken())
        try await app.autoMigrate()
    }) { app in
        try await body(app.db)
    }
}

// MARK: - SchwabAssetType decoding

@Suite("SchwabAssetType decoding")
struct SchwabAssetTypeTests {

    private func decode(_ raw: String) throws -> SchwabAssetType {
        let json = "\"\(raw)\""
        return try JSONDecoder().decode(SchwabAssetType.self, from: Data(json.utf8))
    }

    @Test("EQUITY decodes to .equity") func equity() throws {
        #expect(try decode("EQUITY") == .equity)
    }

    @Test("OPTION decodes to .option") func option() throws {
        #expect(try decode("OPTION") == .option)
    }

    @Test("Unknown value decodes to .other") func unknown() throws {
        #expect(try decode("FIXED_INCOME") == .other)
    }

    @Test("Empty string decodes to .other") func empty() throws {
        #expect(try decode("") == .other)
    }
}

// MARK: - SchwabPosition decoding

@Suite("SchwabPosition decoding")
struct SchwabPositionTests {

    @Test("Decodes all fields via CodingKeys mapping")
    func fullDecode() throws {
        let json = """
        {
            "symbol": "AAPL",
            "assetType": "EQUITY",
            "quantity": 10.0,
            "description": "AAPL  260320C00175000",
            "marketValue": 17500.0
        }
        """.data(using: .utf8)!
        let position = try JSONDecoder().decode(SchwabPosition.self, from: json)
        #expect(position.ticker == "AAPL")
        #expect(position.assetType == .equity)
        #expect(position.quantity == 10.0)
        #expect(position.osiSymbol == "AAPL  260320C00175000")
        #expect(position.marketValue == 17500.0)
    }

    @Test("Optional fields decode as nil when absent")
    func optionalFieldsAbsent() throws {
        let json = """
        { "symbol": "SPY", "assetType": "EQUITY", "quantity": 5.0 }
        """.data(using: .utf8)!
        let position = try JSONDecoder().decode(SchwabPosition.self, from: json)
        #expect(position.ticker == "SPY")
        #expect(position.osiSymbol == nil)
        #expect(position.marketValue == nil)
    }

    @Test("Option position decodes assetType as .option")
    func optionPosition() throws {
        let json = """
        {
            "symbol": "AAPL  260320C00175000",
            "assetType": "OPTION",
            "quantity": 1.0,
            "description": "AAPL  260320C00175000"
        }
        """.data(using: .utf8)!
        let position = try JSONDecoder().decode(SchwabPosition.self, from: json)
        #expect(position.assetType == .option)
        #expect(position.osiSymbol == "AAPL  260320C00175000")
    }
}

// MARK: - authorizedRequest

@Suite("SchwabClient.authorizedRequest")
struct AuthorizedRequestTests {

    @Test("Sets Authorization: Bearer header")
    func setsBearer() {
        let client = makeClient()
        let url = URL(string: "https://api.schwabapi.com/test")!
        let request = client.authorizedRequest(url: url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    }

    @Test("Uses current accessToken value")
    func usesCurrentToken() {
        let client = makeClient()
        client.accessToken = "updated-token"
        let url = URL(string: "https://api.schwabapi.com/test")!
        let request = client.authorizedRequest(url: url)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer updated-token")
    }
}

// MARK: - execute (network mock, serialized to avoid URLProtocol races)

@Suite("SchwabClient.execute", .serialized)
struct ExecuteTests {

    @Test("Returns decoded value on 200")
    func success() async throws {
        struct Greeting: Decodable { let message: String }
        let json = #"{"message":"hello"}"#
        let session = makeMockSession { _ in (Data(json.utf8), mockResponse(statusCode: 200)) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient(session: session)
        let url = URL(string: "https://api.schwabapi.com/test")!
        let request = URLRequest(url: url)
        let result = try await client.execute(request, as: Greeting.self)
        #expect(result.message == "hello")
    }

    @Test("Throws authFailure on 401")
    func authFailure() async throws {
        let session = makeMockSession { _ in (Data(), mockResponse(statusCode: 401)) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient(session: session)
        let url = URL(string: "https://api.schwabapi.com/test")!
        var request = URLRequest(url: url)
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        do {
            _ = try await client.execute(request, as: [String: String].self)
            Issue.record("Expected authFailure to be thrown")
        } catch SchwabError.authFailure { /* expected */ }
    }

    @Test("Throws requestFailed on 500")
    func serverError() async throws {
        let session = makeMockSession { _ in (Data(), mockResponse(statusCode: 500)) }
        defer { MockURLProtocol.handler = nil }
        let client = makeClient(session: session)
        let url = URL(string: "https://api.schwabapi.com/test")!
        let request = URLRequest(url: url)
        do {
            _ = try await client.execute(request, as: [String: String].self)
            Issue.record("Expected requestFailed to be thrown")
        } catch SchwabError.requestFailed(let code) {
            #expect(code == 500)
        }
    }

    @Test("Throws decodingFailed on invalid JSON")
    func decodingError() async throws {
        let session = makeMockSession { _ in (Data("not json".utf8), mockResponse(statusCode: 200)) }
        defer { MockURLProtocol.handler = nil }
        struct Typed: Decodable { let value: Int }
        let client = makeClient(session: session)
        let url = URL(string: "https://api.schwabapi.com/test")!
        let request = URLRequest(url: url)

        do {
            _ = try await client.execute(request, as: Typed.self)
            Issue.record("Expected decodingFailed to be thrown")
        } catch SchwabError.decodingFailed {
            // expected
        }
    }
}

// MARK: - fetchPortfolioPositions

@Suite("SchwabClient.fetchPortfolioPositions")
struct FetchPortfolioPositionsTests {

    @Test("Throws noAccountNumber when accountNumber is empty")
    func emptyAccountNumber() async throws {
        let client = makeClient(accountNumber: "")
        do {
            _ = try await client.fetchPortfolioPositions()
            Issue.record("Expected noAccountNumber to be thrown")
        } catch SchwabError.noAccountNumber {
            // expected
        }
    }
}

// MARK: - refreshTokenIfNeeded (DB-backed)

@Suite("SchwabClient.refreshTokenIfNeeded")
struct RefreshTokenIfNeededTests {

    @Test("Throws noTokenFound when no schwab token exists in DB")
    func noToken() async throws {
        try await withOAuthDB { db in
            let client = makeClient()
            do {
                try await client.refreshTokenIfNeeded(db: db)
                Issue.record("Expected noTokenFound to be thrown")
            } catch SchwabError.noTokenFound {
                // expected
            }
        }
    }

    @Test("Sets accessToken from DB when token is not expired")
    func setsAccessTokenWhenFresh() async throws {
        try await withOAuthDB { db in
            let key = SymmetricKey(size: .bits256)
            let plainAccess = "fresh-access-token"
            let encrypted = try TokenEncryption.encrypt(plainAccess, key: key)

            let token = OAuthToken(
                clerkUserId: "user_test",
                provider: "schwab",
                accessToken: encrypted,
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600)  // 1 hour from now
            )
            try await token.save(on: db)

            let client = SchwabClient(
                accountNumber: "ACC123", clientID: "cid", clientSecret: "csecret",
                encryptionKey: key, accessToken: "")
            try await client.refreshTokenIfNeeded(db: db)

            #expect(client.accessToken == plainAccess)
        }
    }
}
