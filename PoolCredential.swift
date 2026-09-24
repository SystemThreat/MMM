import Foundation
import Security

/// The pool password stays out of preferences, command arguments, and logs.
enum PoolCredential {
    static func account(_ profile:[String:String]) -> String {
        let fields = ["network","host","port","worker","address"].map { profile[$0,default:""] }
        return (try! JSONSerialization.data(withJSONObject:fields)).base64EncodedString()
    }
    private static func query(_ profile:[String:String]) -> [String:Any] {
        [kSecClass as String:kSecClassGenericPassword,
         kSecAttrService as String:"com.xcoin.mmm.pool",
         kSecAttrAccount as String:account(profile)]
    }
    static func load(_ profile:[String:String]) throws -> String {
        var q=query(profile); q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data=result as? Data, let password=String(data:data,encoding:.utf8) else { throw error(status) }
        return password
    }
    static func save(_ password:String, profile:[String:String]) throws {
        let q=query(profile)
        if password.isEmpty {
            let status=SecItemDelete(q as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }; return
        }
        let attributes=[kSecValueData as String:Data(password.utf8)]
        let status=SecItemUpdate(q as CFDictionary,attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item=q; item.merge(attributes) { _,new in new }
            item[kSecAttrAccessible as String]=kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added=SecItemAdd(item as CFDictionary,nil)
            guard added == errSecSuccess else { throw error(added) }
        } else if status != errSecSuccess { throw error(status) }
    }
    /// Delete every saved pool password (all profiles) — the RESET button.
    /// Without kSecMatchLimitAll the file-based login keychain deletes one match.
    static func forgetAll() {
        SecItemDelete([kSecClass as String:kSecClassGenericPassword,
                       kSecAttrService as String:"com.xcoin.mmm.pool",
                       kSecMatchLimit as String:kSecMatchLimitAll] as CFDictionary)
    }
    private static func error(_ status:OSStatus) -> NSError {
        NSError(domain:NSOSStatusErrorDomain,code:Int(status),userInfo:[NSLocalizedDescriptionKey: "Pool password could not be accessed in Keychain. Open Setup and try again. (\(status))"])
    }
}
