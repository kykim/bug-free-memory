//
//  SchwabClient+Portfolio.swift
//  bug-free-memory
//
//  Extends SchwabClient with portfolio position fetching and token refresh.
//

import Fluent
import Foundation

// MARK: - Types

enum SchwabAssetType: String, Codable {
    case equity = "EQUITY"
    case option = "OPTION"
    case other

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SchwabAssetType(rawValue: raw) ?? .other
    }
}

struct SchwabPosition: Codable {
    let ticker: String
    let assetType: SchwabAssetType
    let quantity: Double
    let osiSymbol: String?
    let marketValue: Double?

    enum CodingKeys: String, CodingKey {
        case ticker       = "symbol"
        case assetType    = "assetType"
        case quantity
        case osiSymbol    = "description"
        case marketValue
    }
}

// MARK: - Extension

extension SchwabClient {

    /// Fetches current portfolio positions from Schwab.
    func fetchPortfolioPositions() async throws -> [SchwabPosition] {
        guard !accountNumber.isEmpty else { throw SchwabError.noAccountNumber }
        guard let url = URL(string: "\(Self.traderBaseURL)/accounts/\(accountNumber)/positions") else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        let request = authorizedRequest(url: url)
        return try await execute(request, as: [SchwabPosition].self)
    }

    /// Checks the stored OAuth token for Schwab and refreshes it if expiring within 60 seconds.
    func refreshTokenIfNeeded(db: any Database) async throws {
        guard let tokenRow = try await OAuthToken.query(on: db)
            .filter(\.$provider == "schwab")
            .first() else {
            throw SchwabError.noTokenFound
        }

        if tokenRow.isExpired(buffer: 60) {
            guard let encryptedRefresh = tokenRow.refreshToken else {
                throw SchwabError.noTokenFound
            }
            let plainRefresh = try TokenEncryption.decrypt(encryptedRefresh, key: encryptionKey)
            let (newAccess, newRefresh, expiresIn) = try await refreshToken(refreshToken: plainRefresh)

            tokenRow.accessToken = try TokenEncryption.encrypt(newAccess, key: encryptionKey)
            if let newRefresh {
                tokenRow.refreshToken = try TokenEncryption.encrypt(newRefresh, key: encryptionKey)
            }
            tokenRow.expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn))
            try await tokenRow.save(on: db)

            self.accessToken = newAccess
        } else {
            let plainAccess = try TokenEncryption.decrypt(tokenRow.accessToken, key: encryptionKey)
            self.accessToken = plainAccess
        }
    }
}
