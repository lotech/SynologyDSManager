//
//  AppLogger.swift
//  SynologyDSManager
//
//  Shared `os.Logger` namespaces used across the modernised code. Prefer these
//  over `print(…)` so messages show up in Console.app with the correct
//  subsystem/category and obey the user's log-privacy settings.
//

import Foundation
import os

enum AppLogger {
    /// Apple's `subsystem` convention is reverse-DNS. Keep this in sync with
    /// the CFBundleIdentifier so Console.app can filter by subsystem.
    static let subsystem = "com.skavans.synologyDSManager"

    /// Networking calls to the DSM API. Message bodies MUST NOT contain
    /// credentials, OTP codes, session IDs, or full request URLs that carry
    /// `_sid=` query parameters. Use `%{private}@` for anything derived from
    /// user input.
    static let network = Logger(subsystem: subsystem, category: "network")

    /// Authentication state transitions (login/logout/2FA prompts). Log
    /// *outcomes*, never credentials.
    static let auth = Logger(subsystem: subsystem, category: "auth")

    /// TLS trust evaluation decisions — pinning hits, pinning misses,
    /// first-time-use prompts. SPKI fingerprints are safe to log;
    /// certificate bodies are not.
    static let security = Logger(subsystem: subsystem, category: "security")

    /// Keychain read/write outcomes (success/failure + OSStatus). Never log
    /// the item data itself.
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
}
