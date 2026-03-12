//
//  AppError.swift
//  bug-free-memory
//
//  Created for Kevin Y Kim on 3/12/26.
//
//  Domain-specific error enum for the application HTTP layer.
//  Conforms to `AbortError` so Vapor renders the correct status + reason,
//  and to `Equatable` so unit tests can compare thrown errors directly.
//

import Vapor

enum AppError: AbortError, Equatable {

    // MARK: - OAuth

    /// OAuth callback arrived without an authorization code.
    case oauthMissingCode
    /// No stored OAuth token found for the current session.
    case oauthTokenNotFound
    /// Stored OAuth record exists but has no refresh token.
    case oauthNoRefreshToken

    // MARK: - Input Validation

    /// A date string could not be parsed as yyyy-MM-dd.
    case invalidDateString(String)
    /// An expiration date was provided but falls in the past.
    case expirationDateInPast

    // MARK: - Routing

    /// A required URL route parameter was absent (router matched but param extraction failed).
    case missingRouteParameter(String)
    /// A URL route parameter was present but could not be parsed into the expected type (e.g. UUID).
    case invalidRouteParameter(String)

    // MARK: - Resources

    /// No option contract record exists for the given identifier.
    case contractNotFound
    /// No EOD price history exists for the option's underlying instrument.
    case noUnderlyingPriceData

    // MARK: - Pricing

    /// Option pricing returned nil — inputs or price history are insufficient.
    case pricingFailed

    // MARK: - Configuration

    /// The `TOKEN_ENCRYPTION_KEY` environment variable is missing or malformed at startup.
    case invalidEncryptionKeyConfig

    // MARK: - AbortError

    var status: HTTPResponseStatus {
        switch self {
        case .oauthMissingCode, .oauthTokenNotFound, .oauthNoRefreshToken,
             .missingRouteParameter, .invalidRouteParameter:
            return .badRequest
        case .invalidDateString, .expirationDateInPast, .pricingFailed:
            return .unprocessableEntity
        case .contractNotFound, .noUnderlyingPriceData:
            return .notFound
        case .invalidEncryptionKeyConfig:
            return .internalServerError
        }
    }

    var reason: String {
        switch self {
        case .oauthMissingCode:
            return "Missing OAuth authorization code"
        case .oauthTokenNotFound:
            return "No OAuth token found for this session"
        case .oauthNoRefreshToken:
            return "No refresh token is stored for this session"
        case .invalidDateString(let s):
            return "Invalid date '\(s)', expected yyyy-MM-dd"
        case .expirationDateInPast:
            return "Expiration date must be in the future"
        case .missingRouteParameter(let name):
            return "Missing required route parameter '\(name)'"
        case .invalidRouteParameter(let name):
            return "Route parameter '\(name)' could not be parsed into the expected type"
        case .contractNotFound:
            return "Option contract not found"
        case .noUnderlyingPriceData:
            return "No price data found for underlying instrument"
        case .pricingFailed:
            return "Pricing failed — check inputs or price history"
        case .invalidEncryptionKeyConfig:
            return "TOKEN_ENCRYPTION_KEY must be a base64-encoded 32-byte value"
        }
    }
}
