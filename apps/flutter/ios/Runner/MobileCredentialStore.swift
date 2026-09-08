import Foundation
import Security

enum MobileCredentialStore {
    private static let service = "net.milmit.vpn.mobile.credentials"
    private static let usernameAccount = "username"
    private static let passwordAccount = "password"

    static func save(username: String, password: String) throws {
        guard !username.isEmpty, username.utf8.count <= 256,
              !password.isEmpty, password.utf8.count <= 2048 else {
            throw CredentialError.invalidValue
        }
        try upsert(account: usernameAccount, data: Data(username.utf8))
        try upsert(account: passwordAccount, data: Data(password.utf8))
    }

    static func exists() -> Bool {
        (try? read(account: usernameAccount)) != nil &&
        (try? read(account: passwordAccount)) != nil
    }

    static func load() throws -> (username: String, password: String) {
        let usernameData = try read(account: usernameAccount)
        let passwordData = try read(account: passwordAccount)
        guard let username = String(data: usernameData, encoding: .utf8),
              let password = String(data: passwordData, encoding: .utf8),
              !username.isEmpty, !password.isEmpty else {
            throw CredentialError.invalidValue
        }
        return (username, password)
    }

    static func passwordPersistentReference() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: passwordAccount,
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let ref = result as? Data else {
            throw CredentialError.keychain(status)
        }
        return ref
    }

    private static func upsert(account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add.merge(update) { _, new in new }
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialError.keychain(addStatus) }
        } else if status != errSecSuccess {
            throw CredentialError.keychain(status)
        }
    }

    private static func read(account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw CredentialError.keychain(status)
        }
        return data
    }

    enum CredentialError: LocalizedError {
        case invalidValue
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .invalidValue: return "invalid_credentials"
            case .keychain(let status): return "keychain_error_\(status)"
            }
        }
    }
}
