//
//  AppDelegate.swift
//  SynologyDSManager
//

import Cocoa
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - App entry point

@main
struct SynologyDSManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Synology DS Manager", id: "main") {
            DownloadsView()
                .frame(minWidth: 460, minHeight: 260)
        }
        .defaultSize(width: 600, height: 440)

        MenuBarExtra {
            StatusBarMenuContent()
        } label: {
            MenuBarLabel()
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
        .windowResizability(.contentSize)

        Window("Add Download", id: "add-download") {
            AddDownloadRootView()
        }
        .windowResizability(.contentSize)

        Window("BT Search", id: "bt-search") {
            BTSearchRootView()
        }

        Window("About", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - Menu bar label (separate view so @Observable tracking works)

private struct MenuBarLabel: View {
    var body: some View {
        Text(AppModel.shared.statusBarTitle)
            .monospacedDigit()
    }
}

// MARK: - Menu bar menu content

private struct StatusBarMenuContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Pause all")      { Task { await AppModel.shared.pauseAll() } }
        Button("Start all")      { Task { await AppModel.shared.resumeAll() } }
        Button("Clear finished") { Task { await AppModel.shared.clearFinished() } }
        Divider()
        Button("Show window") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("About") { openWindow(id: "about") }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}

// MARK: - Window root views for scenes with owned state

@MainActor
struct AddDownloadRootView: View {
    @State private var state = AddDownloadState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AddDownloadView(state: state, onClose: { dismiss() })
            .onAppear { consumePendingPaths() }
            .onChange(of: AppModel.shared.pendingTorrentPaths) { _, _ in
                consumePendingPaths()
            }
    }

    private func consumePendingPaths() {
        let paths = AppModel.shared.pendingTorrentPaths
        guard !paths.isEmpty else { return }
        state.taskText = paths.joined(separator: "\n")
        AppModel.shared.pendingTorrentPaths = []
    }
}

@MainActor
struct BTSearchRootView: View {
    @State private var state = BTSearchState()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        BTSearchView(state: state, onClose: { dismiss() })
    }
}

// MARK: - Application delegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Long-lived XPC listener that services the Safari Web Extension.
    private let bridgeListener = SynologyBridgeListener()

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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if let creds = AppModel.shared.loadCredentials() {
            Task { @MainActor in AppModel.shared.startPolling(credentials: creds) }
        }
    }

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

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        var torrentPaths: [String] = []
        for url in urls {
            switch url.scheme {
            case "synologydsmanager":
                if url.host == "download",
                   let queryItems = URLComponents(string: url.absoluteString)?.queryItems,
                   let downloadURL = queryItems.first(where: { $0.name == "downloadURL" }),
                   let value = downloadURL.value, !value.isEmpty {
                    AppModel.shared.enqueueDownload(url: value)
                }
            case "file":
                torrentPaths.append(url.path)
            default:
                break
            }
        }
        if !torrentPaths.isEmpty {
            AppModel.shared.pendingTorrentPaths = torrentPaths
        }
    }
}
