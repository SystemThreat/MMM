import Foundation
import LocalAuthentication
/// Harness double of ForumCredential: never touches the keychain or Touch ID.
enum ForumCredential {
    static var saved: String?
    static var file: String?
    static func exists() -> Bool { saved != nil }
    static func save(_ passphrase: String, file: String) throws { saved = passphrase; self.file = file }
    static func load() throws -> String { guard let saved else { throw NSError(domain: "stub", code: 1) }; return saved }
    static func forget() { saved = nil; file = nil }
    @discardableResult static func authenticate(reason: String = "", _ done: @escaping (Bool, String?) -> Void) -> LAContext {
        DispatchQueue.main.async { done(false, "harness: no Touch ID") }; return LAContext()
    }
}
