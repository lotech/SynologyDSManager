//
//  SynologyTrustEvaluator.swift
//  SynologyDSManager
//
//  TLS trust evaluation for the DSM API client. Replaces the pre-existing
//  Alamofire `DisabledEvaluator()` bypass, which accepted any certificate
//  presented by the NAS and made the connection trivially MITM-able on any
//  untrusted network.
//
//  Design
//  ------
//  Many home Synology installs use a self-signed cert on the default
//  `5001` HTTPS port, so "always require system trust" would break real
//  users. The strategy instead is **trust on first use + SPKI pinning**:
//
//    1. If the server's cert chains to a system-trusted root, accept
//       (standard `URLSession` behaviour).
//    2. Otherwise, look up a **pin** (a SHA-256 hash of the leaf cert's
//       Subject Public Key Info) for this host:
//       * pin matches  → accept
//       * pin present but doesn't match → reject
//       * no pin → reject, and pass the observed fingerprint to the UI
//         via `pendingApproval`. The UI is expected to show the user the
//         fingerprint in a dialog and either call `approve(host:spki:)`
//         or cancel. The request that triggered the prompt will fail; a
//         subsequent request to the same host will succeed once approved.
//
//  This is the same approach used by SSH's `known_hosts` file: explicit
//  user decision the first time, automatic verification thereafter.
//
//  Storage: pins are persisted per-host in `UserDefaults` under the key
//  `"synologyPinnedSPKIs"` as a `[host: [base64-sha256]]` dictionary. Pins
//  are small (32 bytes hashed; ~44 chars base64) and not secret, so
//  UserDefaults is fine — Keychain would be overkill.
//

import Foundation
import CryptoKit

/// Actor that owns the pin store and services `URLSession` trust challenges.
/// Made an actor so the pin dictionary is mutated without locks.
final class SynologyTrustEvaluator: NSObject, URLSessionDelegate, @unchecked Sendable {

    // MARK: - Storage

    private let defaults: UserDefaults
    private let defaultsKey = "synologyPinnedSPKIs"
    private let queue = DispatchQueue(label: "com.skavans.synologyDSManager.trust")

    /// Callback invoked on the main queue when a host presents a
    /// previously-unseen cert and requires user approval. UI should call
    /// `approve(host:spki:)` or leave alone to refuse.
    ///
    /// The closure is retained weakly by convention — the evaluator has
    /// app lifetime, so set this once from `AppDelegate` or equivalent.
    var pendingApproval: (@Sendable (_ host: String, _ spkiBase64: String) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Pin API

    /// Persist a user-approved pin for `host`.
    func approve(host: String, spki: String) {
        queue.sync {
            var all = storedPins()
            var forHost = Set(all[host] ?? [])
            forHost.insert(spki)
            all[host] = Array(forHost)
            defaults.set(all, forKey: defaultsKey)
            AppLogger.security.notice("Approved new pin for \(host, privacy: .private)")
        }
    }

    /// Revoke all pins for a host. Useful after a certificate rotation
    /// that the user wants to re-approve from scratch.
    func revokeAll(for host: String) {
        queue.sync {
            var all = storedPins()
            all.removeValue(forKey: host)
            defaults.set(all, forKey: defaultsKey)
        }
    }

    /// Return the set of SPKI hashes (base64) currently pinned for the host.
    func pins(for host: String) -> Set<String> {
        queue.sync { Set(storedPins()[host] ?? []) }
    }

    private func storedPins() -> [String: [String]] {
        defaults.dictionary(forKey: defaultsKey) as? [String: [String]] ?? [:]
    }

    // MARK: - URLSessionDelegate

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        // Step 1: ask the system. If the cert chains to a trusted CA we're done.
        var secError: CFError?
        if SecTrustEvaluateWithError(serverTrust, &secError) {
            AppLogger.security.debug("System trust accepted cert for \(host, privacy: .private)")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        // Step 2: system rejected. Compute the SPKI fingerprint and check pins.
        guard let spki = Self.spkiSHA256Base64(from: serverTrust) else {
            AppLogger.security.error("Could not extract SPKI from server trust for \(host, privacy: .private)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let existing = pins(for: host)
        if existing.contains(spki) {
            AppLogger.security.notice("Pin hit for \(host, privacy: .private)")
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }

        if !existing.isEmpty {
            // Pin present but doesn't match — refuse. Do NOT auto-prompt
            // in this case; a mismatch could indicate an attacker or a
            // cert rotation. Force the user to explicitly revoke first.
            AppLogger.security.error("Pin mismatch for \(host, privacy: .private) — refusing")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Step 3: first time we've seen this host — hand off to UI for
        // approval. Refuse this particular request so the network call
        // fails loudly; if the user approves, the next attempt will
        // succeed because the pin will be stored.
        AppLogger.security.notice("First-use cert for \(host, privacy: .private) — deferring to UI")
        if let handler = pendingApproval {
            DispatchQueue.main.async {
                handler(host, spki)
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    // MARK: - Fingerprint extraction

    /// Extract the leaf certificate from `SecTrust`, grab its Subject
    /// Public Key Info, and return its SHA-256 digest base64-encoded.
    /// This is the RFC 7469 "pin-sha256" value — the standard primitive
    /// for cert pinning that survives leaf-cert rotation as long as the
    /// same keypair is reused.
    static func spkiSHA256Base64(from trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }
        guard let publicKey = SecCertificateCopyKey(leaf),
              let spkiData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            return nil
        }
        let digest = SHA256.hash(data: spkiData)
        return Data(digest).base64EncodedString()
    }
}
