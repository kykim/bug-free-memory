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
    let ticker: String        // instrument.symbol (OSI symbol for options, ticker for equities; "" if absent)
    let assetType: SchwabAssetType
    let quantity: Double      // longQuantity - shortQuantity
    let osiSymbol: String?    // instrument.symbol when assetType == .option and non-empty, else nil
    let marketValue: Double?
    let cusip: String?        // instrument.cusip
    let underlyingSymbol: String?  // instrument.underlyingSymbol (options only, e.g. "$SPX")

    // Schwab nests symbol/assetType/cusip/underlyingSymbol inside "instrument" and
    // splits quantity into longQuantity / shortQuantity at the top level.
    init(from decoder: any Decoder) throws {
        let top  = try decoder.container(keyedBy: TopKeys.self)
        let inst = try top.nestedContainer(keyedBy: InstrumentKeys.self, forKey: .instrument)
        ticker           = try inst.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        assetType        = try inst.decode(SchwabAssetType.self, forKey: .assetType)
        osiSymbol        = assetType == .option && !ticker.isEmpty ? ticker : nil
        cusip            = try inst.decodeIfPresent(String.self, forKey: .cusip)
        underlyingSymbol = try inst.decodeIfPresent(String.self, forKey: .underlyingSymbol)
        let long         = try top.decodeIfPresent(Double.self, forKey: .longQuantity)  ?? 0
        let short        = try top.decodeIfPresent(Double.self, forKey: .shortQuantity) ?? 0
        quantity         = long - short
        marketValue      = try top.decodeIfPresent(Double.self, forKey: .marketValue)
    }

    private enum TopKeys: String, CodingKey {
        case instrument, longQuantity, shortQuantity, marketValue
    }
    private enum InstrumentKeys: String, CodingKey {
        case symbol, assetType, cusip, underlyingSymbol
    }
}

// MARK: - Extension

extension SchwabClient {

    /// Resolves the plain account number to its Schwab-assigned encrypted hash value.
    private func resolveAccountHash() async throws -> String {
        guard let url = URL(string: "\(Self.traderBaseURL)/accounts/accountNumbers") else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        struct AccountNumberEntry: Decodable {
            let accountNumber: String
            let hashValue: String
        }
        let entries = try await execute(authorizedRequest(url: url), as: [AccountNumberEntry].self)
        guard let match = entries.first(where: { $0.accountNumber == accountNumber }) else {
            throw SchwabError.requestFailed(statusCode: 404)
        }
        return match.hashValue
    }

    /// Fetches current portfolio positions from Schwab.
    func fetchPortfolioPositions() async throws -> [SchwabPosition] {
        guard !accountNumber.isEmpty else { throw SchwabError.noAccountNumber }
        let hash = try await resolveAccountHash()
        guard let url = URL(string: "\(Self.traderBaseURL)/accounts/\(hash)?fields=positions") else {
            throw SchwabError.requestFailed(statusCode: 0)
        }
        let response = try await execute(authorizedRequest(url: url), as: SchwabAccountResponse.self)
        return response.securitiesAccount.positions ?? []
    }

    private struct SchwabAccountResponse: Decodable {
        struct SecuritiesAccount: Decodable {
            let positions: [SchwabPosition]?
        }
        let securitiesAccount: SecuritiesAccount
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
