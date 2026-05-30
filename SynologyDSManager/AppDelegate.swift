//
//  AppDelegate.swift
//  SynologyDSManager
//

import Cocoa
import ServiceManagement
import SwiftUI

// MARK: - App entry point

@main
struct SynologyDSManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            StatusBarMenu()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.menu)
    }
}

// MARK: - Status bar label

// Access AppModel.shared directly rather than via @Environment so that
// @Observable's automatic tracking wires up inside View.body without
// requiring the caller to inject the environment value.
private struct MenuBarLabel: View {
    var body: some View {
        Text(AppModel.shared.statusBarTitle)
            .monospacedDigit()
    }
}

// MARK: - Status bar menu content

struct StatusBarMenu: View {
    var body: some View {
        Button("Pause all")      { mainViewController?.pauseAllToolbarItemClicked(nil) }
        Button("Start all")      { mainViewController?.resumeAllToolbarItemClicked(nil) }
        Button("Clear finished") { mainViewController?.cleanToolbarItemClicked(nil) }
        Divider()
        Button("Show window")    { NSApp.activate(ignoringOtherApps: true) }
        Divider()
        Button("About")          { mainViewController?.aboutMenuItemClicked(nil) }
        Divider()
        Button("Quit")           { NSApplication.shared.terminate(nil) }
    }
}

// MARK: - Application delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Long-lived XPC listener that services the Safari Web Extension's
    /// `SafariWebExtensionHandler`. Retained here so its lifetime
    /// matches the app's.
    private let bridgeListener = SynologyBridgeListener()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Set activation policy before SwiftUI initialises the MenuBarExtra
        // scene so the status-bar item appears on first launch.
        if !(UserDefaults.standard.value(forKey: "hideDockIcon") as? Bool ?? true) {
            NSApp.setActivationPolicy(.regular)
        }

        installCertificateApprovalHandler()
        bridgeListener.start()
        registerBridgeLaunchAgent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSMainStoryboardFile loads the storyboard (giving us the main menu)
        // but we removed initialViewController so AppKit no longer auto-
        // instantiates the Downloads window. Instantiate it by identifier now
        // so viewDidLoad / viewDidAppear fire and the polling loop can start.
        if let wc = NSStoryboard.main?.instantiateController(withIdentifier: "MainWC") as? NSWindowController {
            wc.showWindow(nil)
        }
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
    @MainActor
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
