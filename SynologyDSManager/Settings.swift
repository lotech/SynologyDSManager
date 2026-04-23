//
//  Settings.swift
//  SynologyDSManager
//

import Foundation


/// User-entered connection details persisted to the Keychain between
/// launches. Serialised as JSON.
///
/// The on-disk shape matches what the pre-Phase-2 code produced, so
/// existing installs decode cleanly. Notably, `port` stays a `String`
/// (the UI edits it as a text field) — at the `SynologyAPI` boundary
/// we parse it into an `Int` via `apiCredentials`. Unknown keys like
/// the legacy `sid` field are silently ignored by `Decodable`.
struct StoredCredentials: Codable, Equatable {
    var host: String = ""
    var port: String = "5001"
    var username: String = ""
    var password: String = ""
    var otp: String = ""

    /// Convert to the typed credentials the `SynologyAPI` actor uses.
    /// Falls back to DSM's default HTTPS port `5001` if the stored
    /// string doesn't parse as an `Int`.
    var apiCredentials: SynologyAPI.Credentials {
        SynologyAPI.Credentials(
            host: host,
            port: Int(port) ?? 5001,
            username: username,
            password: password,
            otp: otp.isEmpty ? nil : otp
        )
    }
}


let userDefaults = UserDefaults()
private let credentialsKey = "syno_conn_settings"


/// Persist `credentials` to the Keychain.
func storeSettings(_ credentials: StoredCredentials) {
    do {
        let data = try JSONEncoder().encode(credentials)
        if let string = String(data: data, encoding: .utf8) {
            KeychainStore.write(key: credentialsKey, value: string)
        }
    } catch {
        AppLogger.keychain.error(
            "Failed to encode credentials for keychain: \(error.localizedDescription, privacy: .public)"
        )
    }
}


/// Read credentials from the Keychain. Returns `nil` if nothing has
/// been stored yet or the stored blob can't be decoded.
///
/// Legacy note: an earlier version of the app stored credentials in
/// `UserDefaults` (before moving to the Keychain). If we find them
/// there on startup, migrate them into the Keychain once and remove
/// the `UserDefaults` copy.
func readSettings() -> StoredCredentials? {
    migrateLegacyUserDefaultsCredentialsIfPresent()

    guard let string = KeychainStore.read(key: credentialsKey),
          let data = string.data(using: .utf8) else {
        return nil
    }

    // The Codable decoder silently ignores unknown keys, so existing
    // installs with a stored `sid` field (from before the cookie-based
    // SynologyAPI migration) decode cleanly into the new shape.
    return try? JSONDecoder().decode(StoredCredentials.self, from: data)
}


private func migrateLegacyUserDefaultsCredentialsIfPresent() {
    guard let dict = userDefaults.dictionary(forKey: credentialsKey) else { return }

    if let data = try? JSONSerialization.data(withJSONObject: dict),
       let string = String(data: data, encoding: .utf8) {
        KeychainStore.write(key: credentialsKey, value: string)
    }
    userDefaults.removeObject(forKey: credentialsKey)
}
