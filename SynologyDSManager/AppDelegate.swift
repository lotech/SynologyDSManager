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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the menu-bar status item here — at the single most reliable
        // point in the app lifecycle — rather than inside NSHostingController's
        // view callbacks.  All three of viewDidLoad / init?(coder:) /
        // viewDidAppear fire during NSHostingController's internal SwiftUI
        // setup and the NSStatusItem is silently dropped on macOS 14+.
        createStatusBarItem()
        // Belt-and-suspenders: retry one run-loop later in case the storyboard
        // scene is still being finalised when this fires synchronously.
        DispatchQueue.main.async { [weak self] in self?.createStatusBarItem() }
    }

    private func createStatusBarItem() {
        guard AppModel.shared.statusBarItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let hideSpeed = UserDefaults.standard.bool(forKey: "hideFromStatusBar")
        item.button?.title = hideSpeed ? "↓DS" : "↓DS: 0.0 B/s"

        let menu = NSMenu(title: "Synology DS Manager Status Bar Menu")
        menu.addItem(NSMenuItem.separator())

        for (title, sel) in [
            ("Pause all",      #selector(DownloadsHostingController.pauseAllToolbarItemClicked(_:))),
            ("Start all",      #selector(DownloadsHostingController.resumeAllToolbarItemClicked(_:))),
            ("Clear finished", #selector(DownloadsHostingController.cleanToolbarItemClicked(_:))),
        ] {
            // target=nil → dispatched via the responder chain to whichever
            // object currently handles these selectors (DownloadsHostingController).
            menu.addItem(NSMenuItem(title: title, action: sel, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        let showItem = NSMenuItem(title: "Show window",
                                  action: #selector(showMainWindowFromStatusBar(_:)),
                                  keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())
        let aboutItem = NSMenuItem(title: "About",
                                   action: #selector(DownloadsHostingController.aboutMenuItemClicked(_:)),
                                   keyEquivalent: "")
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        item.menu = menu
        AppModel.shared.statusBarItem = item
        AppLogger.network.debug("Status bar item created")
    }

    @objc private func showMainWindowFromStatusBar(_ sender: AnyObject?) {
        NSApp.activate(ignoringOtherApps: true)
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
    /// self-signed NAS certs can be approved on first use. The callback is
    /// `async`; `await MainActor.run { }` schedules the alert on the main
    /// actor without blocking any thread. `NSAlert.runModal()` runs a nested
    /// event loop, so the main actor stays responsive while the user decides.
    private func installCertificateApprovalHandler() {
        AppModel.shared.trustEvaluator.firstUseDecision = { host, spkiBase64 in
            await MainActor.run {
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
                return alert.runModal() == .alertFirstButtonReturn
            }
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
                    if let vc = currentViewController as? AddDownloadHostingController {
                        vc.populate(with: torrents)
                    }
                }
            }
        }
    }
}
