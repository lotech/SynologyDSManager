//
//  KeychainStore.swift
//  SynologyDSManager
//
//  Thin Swift wrapper around Apple's Keychain Services for storing a
//  single-purpose blob. SynologyDSManager only needs one item — the
//  JSON-encoded `StoredCredentials` written by `Settings.swift` — so
//  this isn't trying to be a general-purpose keychain framework.
//  Scope is deliberately narrow.
//
//  Replaces the KeychainAccess third-party package as of Phase 2b.
//  Because both KeychainAccess's `Keychain(service:)` and this wrapper
//  use `kSecClassGenericPassword` with the same service identifier,
//  items written by the old code transparently read back through the
//  new code — no migration dance required.
//
//  Accessibility
//  -------------
//  Items are stored with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`:
//
//   * "WhenUnlocked" — the Keychain gets locked automatically when
//     the user's Mac screen locks, so stealing an asleep / locked
//     laptop and copying its disk doesn't let an attacker read the
//     credentials offline. macOS only decrypts the blob when the user
//     is logged in and the device is unlocked.
//
//   * "ThisDeviceOnly" — the item does NOT migrate to a different
//     Mac via iCloud Keychain or a restored-from-backup machine. DSM
//     session credentials are tied to the specific Mac that was used
//     to configure them. A user who wants the same setup on a second
//     Mac re-enters their credentials there, which is the correct
//     security posture: a leaked iCloud account shouldn't
//     automatically grant DSM access across all their Macs.
//

import Foundation
import Security


enum KeychainStore {

    /// Matches the service name KeychainAccess used in the pre-2b
    /// code, so pre-existing keychain items are still findable.
    static let service = "com.skavans.synologyDSManager"

    // MARK: - Public API

    /// Read the UTF-8 string stored under `key`, or `nil` if nothing
    /// is stored there (or the stored bytes aren't valid UTF-8).
    /// Logs and returns `nil` for any other error.
    static func read(key: String) -> String? {
        var result: AnyObject?
        let status = SecItemCopyMatching(readQuery(for: key) as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                AppLogger.keychain.error("Keychain read for \(key, privacy: .public) returned non-Data result")
                return nil
            }
            return String(data: data, encoding: .utf8)

        case errSecItemNotFound:
            return nil

        default:
            AppLogger.keychain.error(
                "Keychain read for \(key, privacy: .public) failed with OSStatus \(status, privacy: .public)"
            )
            return nil
        }
    }

    /// Store `value` under `key`, overwriting any previous value.
    /// Logs and silently fails on keychain errors — the app is more
    /// useful without saved credentials than crashed.
    static func write(key: String, value: String) {
        guard let data = value.data(using: .utf8) else {
            AppLogger.keychain.error("Keychain write: value for \(key, privacy: .public) not UTF-8 encodable")
            return
        }

        // `SecItemUpdate` is the canonical "if it exists, replace it"
        // primitive. On errSecItemNotFound we fall through to
        // `SecItemAdd` for the first-time write.
        let updateStatus = SecItemUpdate(
            identityQuery(for: key) as CFDictionary,
            updateFields(data: data) as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return

        case errSecItemNotFound:
            let addStatus = SecItemAdd(addQuery(for: key, data: data) as CFDictionary, nil)
            if addStatus != errSecSuccess {
                AppLogger.keychain.error(
                    "Keychain add for \(key, privacy: .public) failed with OSStatus \(addStatus, privacy: .public)"
                )
            }

        default:
            AppLogger.keychain.error(
                "Keychain update for \(key, privacy: .public) failed with OSStatus \(updateStatus, privacy: .public)"
            )
        }
    }

    /// Delete whatever is stored under `key`. No-op if nothing is there.
    static func delete(key: String) {
        let status = SecItemDelete(identityQuery(for: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogger.keychain.error(
                "Keychain delete for \(key, privacy: .public) failed with OSStatus \(status, privacy: .public)"
            )
        }
    }

    // MARK: - Query builders

    /// Identity of an item: what we use to look it up, update it, or
    /// delete it. Doesn't mention the data or accessibility — those
    /// are attributes we set at write time, not query on.
    private static func identityQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// Identity + instruction to return the stored bytes.
    private static func readQuery(for key: String) -> [String: Any] {
        var query = identityQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return query
    }

    /// Fields changed by an update: just the new bytes + accessibility.
    /// We always rewrite accessibility so a new install gets the new
    /// policy even if the Keychain item was created by an older
    /// version with different attributes.
    private static func updateFields(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
    }

    /// Full attributes for a first-time add: identity + data + accessibility.
    private static func addQuery(for key: String, data: Data) -> [String: Any] {
        var query = identityQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return query
    }
}
