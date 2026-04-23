//
//  AppDelegate.swift
//  SynologyDSManager
//

import Cocoa
import ServiceManagement

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Long-lived XPC listener that services the Safari Web Extension's
    /// `SafariWebExtensionHandler`. Retained here so its lifetime
    /// matches the app's.
    private let bridgeListener = SynologyBridgeListener()

    func applicationWillFinishLaunching(_ notification: Notification) {
        installCertificateApprovalHandler()
        bridgeListener.start()
        registerBridgeLaunchAgent()
    }

    /// Ask launchd to advertise the bridge's Mach service name by
    /// registering our bundled LaunchAgent plist. Safe to call on
    /// every launch — `SMAppService.register()` is idempotent.
    ///
    /// If the plist isn't in the app bundle yet (Phase 3b-2b will
    /// wire the Copy Files build phase that puts it there), this
    /// logs-and-continues rather than failing the launch. The
    /// listener itself still creates cleanly; external callers just
    /// can't reach it until the agent is installed.
    ///
    /// If the user hasn't yet approved the login item, macOS reports
    /// `.requiresApproval` — same outcome from the listener's
    /// perspective (unreachable) but the user sees a prompt in
    /// System Settings. A UX polish pass in a later phase could
    /// surface an in-app nudge pointing at that prompt.
    private func registerBridgeLaunchAgent() {
        let service = SMAppService.agent(plistName: "com.skavans.synologyDSManager.bridge.plist")

        do {
            try service.register()
            AppLogger.security.notice("LaunchAgent registered; bridge reachable via launchd")
        } catch {
            // Diagnose-only: the app works without the bridge. Use
            // public logging for the error domain so Console.app is
            // useful, but keep any identifying paths out of the log.
            AppLogger.security.error(
                "SMAppService.register failed (status=\(service.status.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Wire the shared TLS trust evaluator to an AppKit modal prompt so
    /// self-signed NAS certs can be approved on first use. Runs on the
    /// URLSession delegate queue; the NSAlert must be shown on the main
    /// thread, and the delegate must block until the user decides. We
    /// achieve that with a synchronous `DispatchQueue.main.sync { … }`
    /// — safe here because the delegate queue is neither the main queue
    /// nor a queue any main-thread work depends on.
    private func installCertificateApprovalHandler() {
        synologyTrustEvaluator.firstUseDecision = { host, spkiBase64 in
            var approved = false
            DispatchQueue.main.sync {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Trust this Synology server?"
                alert.informativeText = """
                The server at \(host) presented a certificate that is not signed by a \
                trusted authority. This is normal for a Synology NAS with the default \
                self-signed certificate.

                Only trust this certificate if you recognise the fingerprint below.

                SHA-256 (SPKI):
                \(spkiBase64)
                """
                alert.addButton(withTitle: "Trust")
                alert.addButton(withTitle: "Cancel")
                approved = alert.runModal() == .alertFirstButtonReturn
            }
            return approved
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            DispatchQueue.main.async {

                var torrents: [String] = []

                for url in urls {
                    switch url.scheme {
                    case "synologydsmanager":  // deeplink
                        if url.host == "download" {
                            if let queryItems = URLComponents(string: url.absoluteString)?.queryItems,
                               let downloadURL = queryItems.first(where: { $0.name == "downloadURL" }),
                               let value = downloadURL.value, !value.isEmpty {
                                mainViewController?.downloadByURLFromExtension(URL: value)
                            }
                        }

                    case "file":  // torrent-file to open
                        torrents.append(url.path)

                    default:
                        break
                    }
                }

                if !torrents.isEmpty {
                    mainViewController?.showStoryboardWindowCenteredToMainWindow(
                        storyboardWindowControllerIdentifier: "addDownloadWC"
                    )
                    if let vc = currentViewController as? AddDownloadViewController {
                        vc.torrents = torrents
                        vc.tasksTextView.string = torrents.joined(separator: "\n")
                        vc.tasksTextView.delegate?.textDidChange?(
                            Notification(name: NSNotification.Name("torrentsAdded"))
                        )
                    }
                }
            }
        }
    }
}
