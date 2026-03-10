//
//  TiingoKit+Vapor.swift
//  hello
//
//  Created by Kevin Y Kim on 3/9/26.
//


import Vapor
import TiingoKit

// Make models usable as Vapor responses
extension Tiingo.EODPrice: @retroactive Content {}
extension Tiingo.RealtimeQuote: @retroactive Content {}
extension Tiingo.NewsArticle: @retroactive Content {}

// Application storage
extension Application {
    private struct TiingoClientKey: StorageKey {
        typealias Value = TiingoClient
    }
    public var tiingo: TiingoClient {
        get {
            guard let client = storage[TiingoClientKey.self] else {
                fatalError("TiingoClient not configured. Set app.tiingo in configure.swift")
            }
            return client
        }
        set { storage[TiingoClientKey.self] = newValue }
    }
}

extension Request {
    public var tiingo: TiingoClient { application.tiingo }
}
