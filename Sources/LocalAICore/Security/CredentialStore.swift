import Foundation

/// Well-known credential slots the app manages.
public enum CredentialKey: String, Sendable, CaseIterable, Codable {
    case huggingFaceToken
    case githubToken
    case githubOAuthRefresh
    case huggingFaceOAuthRefresh
}

/// Abstraction over secret storage. Implementations must never log values.
public protocol CredentialStore: Sendable {
    func set(_ value: String, for key: CredentialKey) throws
    func get(_ key: CredentialKey) throws -> String?
    func delete(_ key: CredentialKey) throws
}

public enum CredentialStoreError: Error, Equatable, Sendable {
    case encodingFailed
    case keychainFailure(status: Int)
}

/// Volatile in-memory store — used for tests and as a fallback on platforms
/// without Keychain.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CredentialKey: String] = [:]

    public init() {}

    public func set(_ value: String, for key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func get(_ key: CredentialKey) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func delete(_ key: CredentialKey) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }
}

#if canImport(Security)
import Security

/// Keychain-backed credential store (iOS / macOS only).
public struct KeychainCredentialStore: CredentialStore {
    public static let service = "com.localai.workspace"

    public init() {}

    private func query(for key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: key.rawValue
        ]
    }

    public func set(_ value: String, for key: CredentialKey) throws {
        guard let data = value.data(using: .utf8) else {
            throw CredentialStoreError.encodingFailed
        }
        var q = query(for: key)
        // Try update first.
        let updateStatus = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            throw CredentialStoreError.keychainFailure(status: Int(updateStatus))
        }
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(q as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status: Int(addStatus))
        }
    }

    public func get(_ key: CredentialKey) throws -> String? {
        var q = query(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainFailure(status: Int(status))
        }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func delete(_ key: CredentialKey) throws {
        let status = SecItemDelete(query(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainFailure(status: Int(status))
        }
    }
}
#endif
