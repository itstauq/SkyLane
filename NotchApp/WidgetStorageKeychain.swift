import CryptoKit
import Foundation
import Security

protocol WidgetStorageSecretProviding {
    func masterKey() throws -> Data
    func key(for widgetID: String) throws -> Data
}

enum WidgetStorageKeychainError: LocalizedError {
    case invalidKeyData
    case unhandledStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKeyData:
            return "Keychain returned invalid widget storage key data."
        case .unhandledStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return message
            }
            return "Keychain error \(status)."
        }
    }
}

final class WidgetStorageKeychain: WidgetStorageSecretProviding {
    private let service: String
    private let account: String

    init(
        service: String = "NotchApp Widget Storage",
        account: String = "Encryption Key"
    ) {
        self.service = service
        self.account = account
    }

    func masterKey() throws -> Data {
        if let existing = try loadExistingKey() {
            return existing
        }

        let newKey = randomKey()
        try save(newKey)
        return newKey
    }

    func key(for widgetID: String) throws -> Data {
        let master = try masterKey()
        let derived = HMAC<SHA256>.authenticationCode(
            for: Data(widgetID.utf8),
            using: SymmetricKey(data: master)
        )
        return Data(derived)
    }

    private func loadExistingKey() throws -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else {
                throw WidgetStorageKeychainError.invalidKeyData
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw WidgetStorageKeychainError.unhandledStatus(status)
        }
    }

    private func save(_ key: Data) throws {
        let addQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrLabel: service,
            kSecValueData: key
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateQuery: [CFString: Any] = [
                kSecClass: kSecClassGenericPassword,
                kSecAttrService: service,
                kSecAttrAccount: account
            ]
            let attributes: [CFString: Any] = [
                kSecValueData: key
            ]
            let updateStatus = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw WidgetStorageKeychainError.unhandledStatus(updateStatus)
            }
            return
        }

        guard status == errSecSuccess else {
            throw WidgetStorageKeychainError.unhandledStatus(status)
        }
    }

    private func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Failed to generate widget storage master key.")
        return Data(bytes)
    }
}
