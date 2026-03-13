//
//  SchwabOptionQuoteTests.swift
//  bug-free-memory
//
//  TICKET-009: SchwabOptionQuote decoding + fetchOptionEODPrice tests.
//

import Testing
import Foundation
@testable import bug_free_memory

// MARK: - SchwabOptionQuote decoding

@Suite("SchwabOptionQuote decoding")
struct SchwabOptionQuoteDecodingTests {

    private func decode(_ json: String) throws -> SchwabOptionQuote {
        try JSONDecoder().decode(SchwabOptionQuote.self, from: Data(json.utf8))
    }

    @Test("Decodes all fields including volatility→impliedVolatility remap")
    func fullDecode() throws {
        let json = """
        {
            "bid": 1.25, "ask": 1.35, "last": 1.30,
            "volume": 500, "openInterest": 1200,
            "volatility": 0.32,
            "underlyingPrice": 175.0,
            "delta": 0.45, "gamma": 0.02, "theta": -0.05, "vega": 0.10, "rho": 0.01
        }
        """
        let q = try decode(json)
        #expect(q.bid == 1.25)
        #expect(q.ask == 1.35)
        #expect(q.last == 1.30)
        #expect(q.volume == 500)
        #expect(q.openInterest == 1200)
        #expect(q.impliedVolatility == 0.32)
        #expect(q.underlyingPrice == 175.0)
        #expect(q.delta == 0.45)
        #expect(q.gamma == 0.02)
        #expect(q.theta == -0.05)
        #expect(q.vega == 0.10)
        #expect(q.rho == 0.01)
    }

    @Test("All fields are nil when absent")
    func allNilWhenAbsent() throws {
        let q = try decode("{}")
        #expect(q.bid == nil)
        #expect(q.ask == nil)
        #expect(q.last == nil)
        #expect(q.volume == nil)
        #expect(q.openInterest == nil)
        #expect(q.impliedVolatility == nil)
        #expect(q.underlyingPrice == nil)
        #expect(q.delta == nil)
        #expect(q.gamma == nil)
        #expect(q.theta == nil)
        #expect(q.vega == nil)
        #expect(q.rho == nil)
    }

    @Test("volatility key maps to impliedVolatility; no 'impliedVolatility' key in JSON")
    func volatilityKeyRemap() throws {
        // Confirm "impliedVolatility" as a JSON key is NOT read (Schwab uses "volatility")
        let withWrongKey = try decode(#"{"impliedVolatility": 0.99}"#)
        #expect(withWrongKey.impliedVolatility == nil)

        let withCorrectKey = try decode(#"{"volatility": 0.42}"#)
        #expect(withCorrectKey.impliedVolatility == 0.42)
    }

    @Test("Partial fields decode correctly")
    func partialFields() throws {
        let q = try decode(#"{"bid": 2.00, "ask": 2.10, "volatility": 0.25}"#)
        #expect(q.bid == 2.00)
        #expect(q.ask == 2.10)
        #expect(q.impliedVolatility == 0.25)
        #expect(q.last == nil)
        #expect(q.delta == nil)
    }
}

// MARK: - fetchOptionEODPrice (network mock, serialized)

@Suite("SchwabClient.fetchOptionEODPrice", .serialized)
struct FetchOptionEODPriceTests {

    private let osiSymbol = "AAPL  260320C00175000"

    private func makeClient(handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)) -> SchwabClient {
        MockURLProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return SchwabClient(accountNumber: "ACC123", clientID: "cid", clientSecret: "csecret",
                            encryptionKey: .init(size: .bits256), accessToken: "tok",
                            session: session)
    }

    private func clearMock() {
        MockURLProtocol.handler = nil
    }

    private func resp200(url: URL = URL(string: "https://api.schwabapi.com")!) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    @Test("Returns quote when symbol is present in response")
    func returnsQuoteWhenPresent() async throws {
        let json = """
        {
            "AAPL  260320C00175000": {
                "bid": 1.10, "ask": 1.20, "volatility": 0.30
            }
        }
        """.data(using: .utf8)!
        let client = makeClient { _ in (json, self.resp200()) }
        defer { clearMock() }
        let quote = try await client.fetchOptionEODPrice(osiSymbol: osiSymbol)
        #expect(quote != nil)
        #expect(quote?.bid == 1.10)
        #expect(quote?.ask == 1.20)
        #expect(quote?.impliedVolatility == 0.30)
    }

    @Test("Returns nil when symbol is absent from response")
    func returnsNilWhenAbsent() async throws {
        let json = "{}".data(using: .utf8)!
        let client = makeClient { _ in (json, self.resp200()) }
        defer { clearMock() }
        let quote = try await client.fetchOptionEODPrice(osiSymbol: osiSymbol)
        #expect(quote == nil)
    }

    @Test("Request URL contains percent-encoded OSI symbol")
    func urlEncoding() async throws {
        nonisolated(unsafe) var capturedURL: URL?
        let json = "{}".data(using: .utf8)!
        let client = makeClient { req in
            capturedURL = req.url
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { clearMock() }
        _ = try await client.fetchOptionEODPrice(osiSymbol: osiSymbol)
        let urlString = capturedURL?.absoluteString ?? ""
        #expect(urlString.contains("AAPL"))
        #expect(!urlString.contains(" "))
        #expect(urlString.contains("quotes?symbols="))
    }

    @Test("Request carries Authorization: Bearer header")
    func authHeader() async throws {
        nonisolated(unsafe) var capturedRequest: URLRequest?
        let json = "{}".data(using: .utf8)!
        let client = makeClient { req in
            capturedRequest = req
            return (json, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        defer { clearMock() }
        _ = try await client.fetchOptionEODPrice(osiSymbol: osiSymbol)
        #expect(capturedRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test("Throws authFailure on 401")
    func authFailure() async throws {
        let client = makeClient { _ in (Data(), HTTPURLResponse(url: URL(string: "https://api.schwabapi.com")!,
                                                                statusCode: 401, httpVersion: nil, headerFields: nil)!) }
        defer { clearMock() }
        do {
            _ = try await client.fetchOptionEODPrice(osiSymbol: osiSymbol)
            Issue.record("Expected authFailure")
        } catch SchwabError.authFailure { /* expected */ }
    }
}
