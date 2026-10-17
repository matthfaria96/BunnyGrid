#if DEBUG
import Foundation
import Testing
@testable import BunnyGridCore

/// The in-memory Keychain used by UI scenarios (`BUNNYGRID_MEMORY_KEYCHAIN=1`).
struct MemoryKeychainTests {
    @Test func storesAndRemovesValues() {
        let keychain = MemoryKeychain()
        #expect(keychain.get("service/account") == nil)
        keychain.set("secret", "service/account")
        #expect(keychain.get("service/account") == "secret")
        keychain.set("", "service/account")
        #expect(keychain.get("service/account") == nil)
        keychain.set("again", "service/account")
        keychain.set(nil, "service/account")
        #expect(keychain.get("service/account") == nil)
    }

    @Test func isOffUnlessRequested() {
        // The test process does not set BUNNYGRID_MEMORY_KEYCHAIN.
        #expect((MemoryKeychain.shared != nil) == (ProcessInfo.processInfo.environment["BUNNYGRID_MEMORY_KEYCHAIN"] == "1"))
    }
}
#endif
