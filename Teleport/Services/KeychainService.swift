import Foundation
import Security

enum KeychainError: LocalizedError {
    case unhandledError(OSStatus)
    case itemNotFound
    case unexpectedData

    var errorDescription: String? {
        switch self {
        case .unhandledError(let status):
            return SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        case .itemNotFound:
            return "Password not found in Keychain"
        case .unexpectedData:
            return "Unexpected Keychain data format"
        }
    }
}

struct KeychainService {
    static let service = "com.teleport.app"

    static func save(password: String, for connectionID: UUID) throws {
        let data = Data(password.utf8)
        let key = connectionID.uuidString

        // Try to update first
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            // Stay on this device; never sync to iCloud Keychain. Only readable
            // when the device is unlocked.
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            addQuery[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(status)
        }
    }

    static func load(for connectionID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      connectionID.uuidString,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let password = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedData
            }
            return password
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unhandledError(status)
        }
    }

    /// Delete the keychain item for `connectionID`. Returns `true` on success
    /// or when no item existed; `false` if the keychain refused the delete.
    @discardableResult
    static func delete(for connectionID: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
