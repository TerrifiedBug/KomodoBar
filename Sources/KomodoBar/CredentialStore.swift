import Foundation
import KomodoBarCore

/// Persists the Komodo connection: base URL + API key in `UserDefaults`, the API
/// secret in the Keychain. Mirrors the official client's env-var names where it
/// matters (`KOMODO_ADDRESS`/`KOMODO_API_KEY`/`KOMODO_API_SECRET`).
enum CredentialStore {
    private enum Key {
        static let address = "komodo.address"
        static let apiKey = "komodo.apiKey"
        static let secretAccount = "api-secret"
    }

    static var address: String {
        get { UserDefaults.standard.string(forKey: Key.address) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.address) }
    }

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: Key.apiKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.apiKey) }
    }

    static var apiSecret: String {
        get { Keychain.get(account: Key.secretAccount) ?? "" }
        set {
            if newValue.isEmpty { Keychain.delete(account: Key.secretAccount) }
            else { Keychain.set(newValue, account: Key.secretAccount) }
        }
    }

    /// A usable credentials value, or nil if not fully configured.
    static func load() -> KomodoCredentials? {
        KomodoCredentials(urlString: address, apiKey: apiKey, apiSecret: apiSecret)
            .flatMap { !apiKey.isEmpty && !apiSecret.isEmpty ? $0 : nil }
    }

    static func save(address: String, apiKey: String, apiSecret: String) {
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiSecret = apiSecret
    }
}
