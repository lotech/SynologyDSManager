//
//  AppDelegate.swift
//  SynologyDSManager
//

import Cocoa

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        installCertificateApprovalHandler()
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
