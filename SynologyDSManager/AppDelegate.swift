//
//  AppDelegate.swift
//  SynologyDSManager
//

import Cocoa
import Observation
import ServiceManagement
import SwiftUI

// MARK: - App entry point

@main
struct SynologyDSManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // SwiftUI requires at least one scene. This placeholder creates no
        // visible UI. The status bar item is managed by NSStatusBar in
        // AppDelegate (reliable on all macOS versions). The main window comes
        // from the storyboard loaded in applicationDidFinishLaunching.
        //
        // TODO: Replace with MenuBarExtra once macOS 26.x resolves the silent
        //       scene-registration failure that prevents it from appearing.
        Settings { EmptyView() }
    }
}

// MARK: - Application delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Long-lived XPC listener that services the Safari Web Extension.
    private let bridgeListener = SynologyBridgeListener()

    /// The status bar item that shows download speed and opens the menu.
    private var statusItem: NSStatusItem?

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        if !(UserDefaults.standard.value(forKey: "hideDockIcon") as? Bool ?? true) {
            NSApp.setActivationPolicy(.regular)
        }
        installCertificateApprovalHandler()
        bridgeListener.start()
        registerBridgeLaunchAgent()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let storyboard = NSStoryboard(name: "Main", bundle: nil)
        if let wc = storyboard.instantiateController(withIdentifier: "MainWC") as? NSWindowController {
            wc.showWindow(nil)
        }
        setupStatusItem()
    }

    // MARK: - Status bar item

    @MainActor
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.menu = buildStatusMenu()
        observeStatusBarTitle()
    }

    /// Re-registers observation on every change so the title stays in sync
    /// with AppModel.shared.statusBarTitle throughout the app's lifetime.
    @MainActor
    private func observeStatusBarTitle() {
        withObservationTracking {
            statusItem?.button?.title = AppModel.shared.statusBarTitle
        } onChange: {
            Task { @MainActor [weak self] in
                self?.observeStatusBarTitle()
            }
        }
    }

    private func buildStatusMenu() -> NSMenu {
        let menu = NSMenu()

        func add(_ title: String, _ sel: Selector) {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        add("Pause all",      #selector(pauseAll))
        add("Start all",      #selector(startAll))
        add("Clear finished", #selector(clearFinished))
        menu.addItem(.separator())
        add("Show window",    #selector(showWindow))
        menu.addItem(.separator())
        add("About",          #selector(showAbout))
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    @objc private func pauseAll()      { mainViewController?.pauseAllToolbarItemClicked(nil) }
    @objc private func startAll()      { mainViewController?.resumeAllToolbarItemClicked(nil) }
    @objc private func clearFinished() { mainViewController?.cleanToolbarItemClicked(nil) }
    @objc private func showWindow()    { NSApp.activate(ignoringOtherApps: true) }
    @objc private func showAbout()     { mainViewController?.aboutMenuItemClicked(nil) }

    // MARK: - Bridge / TLS helpers

    private func registerBridgeLaunchAgent() {
        let service = SMAppService.agent(plistName: "com.skavans.synologyDSManager.bridge.plist")
        do {
            try service.register()
            AppLogger.security.notice("LaunchAgent registered; bridge reachable via launchd")
        } catch {
            AppLogger.security.error(
                "SMAppService.register failed (status=\(service.status.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

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

    // MARK: - URL / file open

    func application(_ application: NSApplication, open urls: [URL]) {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            DispatchQueue.main.async {
                var torrents: [String] = []

                for url in urls {
                    switch url.scheme {
                    case "synologydsmanager":
                        if url.host == "download",
                           let queryItems = URLComponents(string: url.absoluteString)?.queryItems,
                           let downloadURL = queryItems.first(where: { $0.name == "downloadURL" }),
                           let value = downloadURL.value, !value.isEmpty {
                            mainViewController?.downloadByURLFromExtension(URL: value)
                        }

                    case "file":
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
