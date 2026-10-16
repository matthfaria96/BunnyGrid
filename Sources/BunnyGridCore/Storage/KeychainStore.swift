import Foundation
import Security

/// Stores connection passwords as generic passwords in the login Keychain,
/// keyed by the connection's UUID.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "app.bunnygrid.connections") {
        self.service = service
    }

    public func password(for id: UUID) -> String? {
        password(account: id.uuidString)
    }

    public func setPassword(_ password: String?, for id: UUID) {
        setPassword(password, account: id.uuidString)
    }

    public func password(account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var query = baseQuery(account)
        query[kSecValueData as String] = Data(password.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(query as CFDictionary, nil)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
