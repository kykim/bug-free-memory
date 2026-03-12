//
//  OAuthToken.swift
//  bug-free-memory
//
//  Created by Kevin Y Kim on 3/12/26.
//


import Fluent
import Vapor

final class OAuthToken: Model, Content, @unchecked Sendable {
    static let schema = "oauth_tokens"

    @ID(key: .id)
    var id: UUID?

    /// Clerk user ID (e.g. "user_abc123")
    @Field(key: "clerk_user_id")
    var clerkUserId: String

    /// e.g. "schwab", "google"
    @Field(key: "provider")
    var provider: String

    /// Encrypted access token
    @Field(key: "access_token")
    var accessToken: String

    /// Encrypted refresh token
    @OptionalField(key: "refresh_token")
    var refreshToken: String?

    /// Scopes granted, stored as a space-separated string
    @OptionalField(key: "scope")
    var scope: String?

    /// When the access token expires
    @Field(key: "expires_at")
    var expiresAt: Date

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        clerkUserId: String,
        provider: String,
        accessToken: String,
        refreshToken: String? = nil,
        scope: String? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.clerkUserId = clerkUserId
        self.provider = provider
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.scope = scope
        self.expiresAt = expiresAt
    }

    /// Returns true if the access token is expired or expiring within the given buffer.
    func isExpired(buffer: TimeInterval = 60) -> Bool {
        expiresAt.timeIntervalSinceNow < buffer
    }
}
