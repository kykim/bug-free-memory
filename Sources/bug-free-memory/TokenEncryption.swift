import Crypto
import Foundation
import Vapor

enum TokenEncryption {
    enum EncryptionError: Error {
        case encryptionFailed
        case decryptionFailed
    }

    static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> String {
        let data = Data(plaintext.utf8)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw EncryptionError.encryptionFailed
        }
        return combined.base64EncodedString()
    }

    static func decrypt(_ ciphertext: String, key: SymmetricKey) throws -> String {
        guard let data = Data(base64Encoded: ciphertext) else {
            throw EncryptionError.decryptionFailed
        }
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        let decryptedData = try AES.GCM.open(sealedBox, using: key)
        guard let plaintext = String(data: decryptedData, encoding: .utf8) else {
            throw EncryptionError.decryptionFailed
        }
        return plaintext
    }
}

extension Application {
    struct TokenEncryptionKeyStorage: StorageKey {
        typealias Value = SymmetricKey
    }

    var tokenEncryptionKey: SymmetricKey {
        get { storage[TokenEncryptionKeyStorage.self]! }
        set { storage[TokenEncryptionKeyStorage.self] = newValue }
    }
}
