import Foundation
import Security

/// Storage seam for secret key material. Real impl uses the iOS Keychain;
/// tests use an in-memory fake.
protocol KeychainBacking {
    func set(_ data: Data, for id: String)
    func get(_ id: String) -> Data?
    func ids() -> [String]
    func remove(_ id: String)
}

/// In-memory fake for unit tests.
final class InMemoryKeychain: KeychainBacking {
    private var store: [String: Data] = [:]
    func set(_ data: Data, for id: String) { store[id] = data }
    func get(_ id: String) -> Data? { store[id] }
    func ids() -> [String] { Array(store.keys) }
    func remove(_ id: String) { store[id] = nil }
}

/// iOS Keychain-backed store. Not unit-tested (requires entitlement/device)
/// but must compile.
final class RealKeychain: KeychainBacking {
    static let defaultService = "com.codem0nky87.MultiSessionAIManager.keys"
    private let service: String

    init(service: String = RealKeychain.defaultService) {
        self.service = service
    }

    func set(_ data: Data, for id: String) {
        // Delete any existing item first so this is an upsert.
        remove(id)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    func get(_ id: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    func ids() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    func remove(_ id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
