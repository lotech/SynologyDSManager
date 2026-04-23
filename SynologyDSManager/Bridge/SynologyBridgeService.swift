//
//  SynologyBridgeService.swift
//  SynologyDSManager
//
//  Concrete implementation of `SynologyBridgeProtocol`. One of these
//  is vended per incoming XPC connection by `SynologyBridgeListener`.
//  Each call delegates to `SynologyAPI.createTask(url:)` with the
//  user's currently-configured destination picked up from
//  `UserDefaults` (same path the Safari App Extension used pre-Phase-3).
//

import Foundation


/// Lives on the XPC connection's request-handling thread, not the main
/// actor. `NSXPCConnection`'s thread model means a given connection's
/// calls are serialised but may run on a private queue, so the service
/// hops to the main actor when it needs to read the
/// `destinationSelectedPath_extension` user default (which, like the
/// rest of `Shared.swift` state, is treated as main-thread-only).
///
/// `NSObject` + `@objc` because `NSXPCConnection` requires it.
final class SynologyBridgeService: NSObject, SynologyBridgeProtocol {

    func enqueueDownload(url: String, reply: @escaping (Bool, String?) -> Void) {
        // Reject obviously-bad input up front so we don't bother the
        // main actor / DSM on trivially invalid requests.
        guard let trimmed = Self.sanitised(url) else {
            reply(false, "Invalid or unsupported URL.")
            return
        }

        Task {
            guard let api = await MainActor.run(body: { synologyAPI }) else {
                reply(false, "Not signed in to Download Station.")
                return
            }
            let destination = await MainActor.run {
                userDefaults.string(forKey: "destinationSelectedPath_extension")
            }

            do {
                try await api.createTask(url: trimmed, destination: destination)
                AppLogger.network.notice("Bridge enqueued \(trimmed, privacy: .private) via XPC")
                reply(true, nil)
            } catch {
                let description = error.localizedDescription
                AppLogger.network.error(
                    "Bridge createTask failed: \(description, privacy: .public)"
                )
                reply(false, description)
            }
        }
    }

    // MARK: - Input sanitisation

    /// Reject input that obviously isn't a download URL before
    /// forwarding to DSM. Anything that gets past this is still
    /// treated as untrusted by the rest of the code — this is a
    /// front-line filter, not a security boundary by itself.
    private static func sanitised(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096 else { return nil }

        // DSM accepts the usual protocol schemes for downloads.
        let allowedSchemes = ["http://", "https://", "ftp://", "ftps://", "magnet:", "ed2k://"]
        guard allowedSchemes.contains(where: trimmed.hasPrefix) else { return nil }

        return trimmed
    }
}
