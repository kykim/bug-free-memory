//
//  SchwabClient.swift
//  bug-free-memory
//
//  HTTP client for the Schwab API. Access token is loaded from the
//  database on demand via refreshTokenIfNeeded(db:).
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Vapor
import Crypto

// MARK: - Errors

enum SchwabError: Error {
    case noTokenFound
    case authFailure
    case requestFailed(statusCode: Int)
    case decodingFailed(any Error)
    case noAccountNumber
}

// MARK: - Token refresh response

private struct SchwabOAuthTokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int
}

// MARK: - SchwabClient

final class SchwabClient: @unchecked Sendable {

    // Base URLs
    static let traderBaseURL     = "https://api.schwabapi.com/trader/v1"
    static let marketDataBaseURL = "https://api.schwabapi.com/marketdata/v1"
    static let oauthTokenURL     = "https://api.schwabapi.com/v1/oauth/token"

    let accountNumber: String
    let clientID: String
    let clientSecret: String
    let encryptionKey: SymmetricKey

    /// Current decrypted access token. Updated by refreshTokenIfNeeded.
    var accessToken: String

    /// URLSession used for all HTTP requests. Injectable for testing.
    let session: URLSession

    init(
        accountNumber: String,
        clientID: String,
        clientSecret: String,
        encryptionKey: SymmetricKey,
        accessToken: String = "",
        session: URLSession = .shared
    ) {
        self.accountNumber = accountNumber
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.encryptionKey = encryptionKey
        self.accessToken = accessToken
        self.session = session
    }

    // MARK: - Token Refresh

    /// Exchanges a refresh token for a new access token via Schwab OAuth2.
    func refreshToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String?, expiresIn: Int) {
        guard let url = URL(string: Self.oauthTokenURL) else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let credentials = "\(clientID):\(clientSecret)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")

        let body = "grant_type=refresh_token&refresh_token=\(refreshToken)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        if httpResponse.statusCode == 401 { throw SchwabError.authFailure }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SchwabError.requestFailed(statusCode: httpResponse.statusCode)
        }

        do {
            let tokenResponse = try JSONDecoder().decode(SchwabOAuthTokenResponse.self, from: data)
            return (tokenResponse.access_token, tokenResponse.refresh_token, tokenResponse.expires_in)
        } catch {
            throw SchwabError.decodingFailed(error)
        }
    }

    // MARK: - Helpers

    /// Builds an authorized URLRequest for a Schwab API endpoint.
    func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Executes a request and returns decoded JSON. Throws SchwabError.authFailure on 401.
    func execute<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        if httpResponse.statusCode == 401 { throw SchwabError.authFailure }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SchwabError.requestFailed(statusCode: httpResponse.statusCode)
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SchwabError.decodingFailed(error)
        }
    }
}

// MARK: - Application storage

extension Application {
    struct SchwabClientKey: StorageKey {
        typealias Value = SchwabClient
    }
    var schwab: SchwabClient? {
        get { storage[SchwabClientKey.self] }
        set { storage[SchwabClientKey.self] = newValue }
    }
}
