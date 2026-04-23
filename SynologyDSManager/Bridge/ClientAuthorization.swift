//
//  ClientAuthorization.swift
//  SynologyDSManager
//
//  Code-signature-based peer authorisation for the `SynologyBridgeListener`.
//  Only XPC clients signed by our Apple Developer Team whose bundle
//  identifier is on the explicit allow-list can complete an XPC
//  handshake with the main app. Anything else (an attacker's random
//  local binary, a maliciously-modified version of our own code, a
//  process with a wrong team ID) is refused before the first protocol
//  method runs.
//
//  This is a belt-and-braces layer. macOS XPC doesn't enforce any of
//  this by default — anyone can try to connect to a public
//  `NSXPCListener`. The native messaging host (Phase 3b) is our only
//  legitimate peer; spelling that out here is cheap and catches
//  drift if a future refactor accidentally exposes new callers.
//

import Foundation
import Security


/// `NSXPCConnection.auditToken` exists — it's declared in
/// `<Foundation/NSXPCConnection_Private.h>` and has been stable since
/// macOS 10.7 — but Swift doesn't import SPI headers, so the property
/// isn't visible on the Swift type. The canonical workaround (used by
/// Apple's own sample code and every serious open-source XPC helper)
/// is to redeclare the selector on a private `@objc` protocol and
/// `unsafeBitCast` the connection to it. This is a Developer ID app,
/// not Mac App Store, so calling SPI here is acceptable; an equivalent
/// `xpc_connection_get_audit_token` path exists but is equally SPI.
@objc private protocol _NSXPCConnectionAuditToken {
    var auditToken: audit_token_t { get }
}


enum ClientAuthorization {

    /// Bundle identifier of the only process we expect to connect to
    /// the bridge. Phase 3b's Safari Web Extension target (a
    /// `Contents/PlugIns/*.appex` inside the main app) is signed with
    /// this identifier; its `SafariWebExtensionHandler` subclass is
    /// the XPC client on the other end of the listener.
    static let allowedPeerBundleIdentifier = "com.skavans.synologyDSManager.bridge"

    /// Check whether the peer of the given `NSXPCConnection` is
    /// acceptable. Returns `true` if the peer:
    ///   1. has a valid code signature,
    ///   2. is signed by the same Apple Developer Team as ourselves,
    ///   3. declares the bundle identifier we expect.
    ///
    /// Logs via `AppLogger.security` on refusal so the reason is
    /// visible in Console.app without leaking identifiers to
    /// untrusted log destinations.
    static func isTrusted(connection: NSXPCConnection) -> Bool {
        // Extract the peer's audit token — `auditToken` is a fixed
        // identifier for the peer process that can't be race-confused
        // the way a PID can be reused after exit. Reached via the
        // `_NSXPCConnectionAuditToken` protocol cast above.
        var token = unsafeBitCast(connection, to: _NSXPCConnectionAuditToken.self).auditToken
        let tokenData = withUnsafePointer(to: &token) {
            Data(bytes: $0, count: MemoryLayout<audit_token_t>.size)
        }

        let attributes: CFDictionary = [
            kSecGuestAttributeAudit: tokenData,
        ] as CFDictionary

        var guestCode: SecCode?
        let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &guestCode)
        guard copyStatus == errSecSuccess, let guestCode else {
            AppLogger.security.error("ClientAuth: SecCodeCopyGuestWithAttributes failed \(copyStatus, privacy: .public)")
            return false
        }

        // Build a designated requirement that accepts only:
        //   - Apple's root trust chain,
        //   - our own Team ID,
        //   - the bundle identifier we expect for the native host.
        guard let teamID = currentTeamID(), !teamID.isEmpty else {
            AppLogger.security.error("ClientAuth: couldn't read our own Team ID; refusing all peers")
            return false
        }
        let requirementText = "anchor apple generic"
            + " and certificate leaf[subject.OU] = \"\(teamID)\""
            + " and identifier = \"\(allowedPeerBundleIdentifier)\""

        var requirement: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard reqStatus == errSecSuccess, let requirement else {
            AppLogger.security.error("ClientAuth: SecRequirementCreateWithString failed \(reqStatus, privacy: .public)")
            return false
        }

        let validityStatus = SecCodeCheckValidity(guestCode, [], requirement)
        if validityStatus != errSecSuccess {
            AppLogger.security.error("ClientAuth: peer failed signature / identifier check with \(validityStatus, privacy: .public)")
            return false
        }

        AppLogger.security.notice("ClientAuth: peer \(allowedPeerBundleIdentifier, privacy: .public) accepted")
        return true
    }

    /// Read our own app's Team ID from its code signature. Used to
    /// build the requirement so we don't have to hard-code a Team ID
    /// in the source (it's per-maintainer and intentionally kept out
    /// of the public repo via the `Signing.xcconfig` cascade).
    static func currentTeamID() -> String? {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else {
            return nil
        }

        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
