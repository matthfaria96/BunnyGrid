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
        #if DEBUG
        // Screenshots against disposable servers: `BUNNYGRID_DEBUG_PASSWORD` stands in for every saved password,
        // so a scratch data dir never needs Keychain items.
        if let override = ProcessInfo.processInfo.environment["BUNNYGRID_DEBUG_PASSWORD"] { return override }
        #endif
        return password(account: id.uuidString)
    }

    public func setPassword(_ password: String?, for id: UUID) {
        setPassword(password, account: id.uuidString)
    }

    /// Account of the SSH password or private key passphrase for a connection.
    public static func sshAccount(for id: UUID) -> String { id.uuidString + ".ssh" }
    /// Account of the SSL client key passphrase for a connection.
    public static func sslKeyAccount(for id: UUID) -> String { id.uuidString + ".ssl-key" }

    /// Every secret saved for a connection: database password, SSH secret and SSL key passphrase.
    public func secrets(for id: UUID) -> ConnectionSecrets {
        ConnectionSecrets(
            password: password(for: id),
            sshSecret: password(account: Self.sshAccount(for: id)),
            sslKeyPassphrase: password(account: Self.sslKeyAccount(for: id))
        )
    }

    /// Saves all of a connection's secrets; nil and empty values remove the item.
    public func setSecrets(_ secrets: ConnectionSecrets, for id: UUID) {
        setPassword(secrets.password, for: id)
        setPassword(secrets.sshSecret, account: Self.sshAccount(for: id))
        setPassword(secrets.sslKeyPassphrase, account: Self.sslKeyAccount(for: id))
    }

    public func password(account: String) -> String? {
        #if DEBUG
        if let memory = MemoryKeychain.shared { return memory.get(service + "/" + account) }
        #endif
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, account: String) {
        #if DEBUG
        if let memory = MemoryKeychain.shared { return memory.set(password, service + "/" + account) }
        #endif
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

#if DEBUG
/// `BUNNYGRID_MEMORY_KEYCHAIN=1` (debug builds, UI scenarios): secrets live in memory for the process, so
/// scripted runs never read or write the login Keychain.
final class MemoryKeychain: @unchecked Sendable {
    static let shared: MemoryKeychain? = ProcessInfo.processInfo.environment["BUNNYGRID_MEMORY_KEYCHAIN"] == "1" ? MemoryKeychain() : nil

    private let lock = NSLock()
    private var items: [String: String] = [:]

    func get(_ key: String) -> String? { lock.withLock { items[key] } }

    func set(_ value: String?, _ key: String) {
        lock.withLock { items[key] = (value?.isEmpty ?? true) ? nil : value }
    }
}
#endif
