import Foundation
import Security
import LocalAuthentication

/// The wallet passphrase, shared by the two features that unlock the wallet:
/// one-click forum sign-in and WALLET-tab sends. Stored in the login keychain
/// like the pool password, and read back only after the user passes Touch ID
/// (or the Mac password when Touch ID is unavailable — a closed lid, for
/// example), with the prompt naming the exact action being approved.
/// Forgetting it (SETUP tab) deletes the item for both features.
/// It is bound to the wallet file it was verified against (`file`: the file's
/// identity key, App.walletFileKey) and unlocks nothing else.
enum ForumCredential {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.xcoin.mmm.wallet-passphrase",
        kSecAttrAccount as String: "wallet.mmm",
    ]
    static func exists() -> Bool {
        var q = query; q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }
    static var file: String? {
        get { UserDefaults.standard.string(forKey: "walletCredFile") }
        set { UserDefaults.standard.set(newValue, forKey: "walletCredFile") }
    }
    static func save(_ passphrase: String, file: String) throws {
        try save(passphrase)
        if !passphrase.isEmpty { self.file = file }
    }
    private static func save(_ passphrase: String) throws {
        guard !passphrase.isEmpty else { return }
        let attributes = [kSecValueData as String: Data(passphrase.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query; item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw error(added) }
        } else if status != errSecSuccess { throw error(status) }
    }
    static func load() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let pw = String(data: data, encoding: .utf8) else { throw error(status) }
        return pw
    }
    static func forget() { SecItemDelete(query as CFDictionary); file = nil }
    /// Touch ID, falling back to the Mac password — never skipped. The reason
    /// is shown in the system prompt, so callers say exactly what is approved.
    static func authenticate(reason: String = "sign in to MineDifferent with your saved wallet passphrase", _ done: @escaping (Bool, String?) -> Void) {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            done(false, err?.localizedDescription ?? "Touch ID is not available on this Mac."); return
        }
        ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, e in
            DispatchQueue.main.async { done(ok, ok ? nil : (e?.localizedDescription ?? "authentication failed")) }
        }
    }
    private static func error(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "The wallet passphrase could not be accessed in Keychain. (\(status))"])
    }
}
