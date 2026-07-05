import Foundation
#if canImport(Security)
import Security
#endif

public protocol KeychainStore: Sendable {
    func secret(for key: String) throws -> String?
    func setSecret(_ secret: String, for key: String) throws
    func deleteSecret(for key: String) throws
}

public final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func secret(for key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func setSecret(_ secret: String, for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = secret
    }

    public func deleteSecret(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

#if canImport(Security)
public struct MacKeychainStore: KeychainStore {
    public let service: String

    public init(service: String = "dev.openfinder") {
        self.service = service
    }

    public func secret(for key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw OpenFinderError.operationFailed("Keychain read failed: \(status)") }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ secret: String, for key: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw OpenFinderError.operationFailed("Keychain update failed: \(updateStatus)")
        }
        var add = query
        add[kSecValueData as String] = data
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OpenFinderError.operationFailed("Keychain add failed: \(addStatus)")
        }
    }

    public func deleteSecret(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw OpenFinderError.operationFailed("Keychain delete failed: \(status)")
        }
    }
}
#endif
