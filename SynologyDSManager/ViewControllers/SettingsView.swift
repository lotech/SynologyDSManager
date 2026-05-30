//
//  SettingsView.swift
//  SynologyDSManager
//
//  SwiftUI replacement for SettingsViewController (Phase 4, slice 1).
//  Hosted by SettingsHostingController which is wired into Main.storyboard
//  in place of the old SettingsViewController.
//

import SwiftUI
import SafariServices.SFSafariApplication


// MARK: - DestinationView bridge

/// Wraps the AppKit DestinationView XIB for use inside SwiftUI until the
/// Choose Destination screen is ported to SwiftUI later in Phase 4.
struct DestinationViewRepresentable: NSViewRepresentable {
    let synchronizeKey: String

    func makeNSView(context: Context) -> DestinationView {
        let view = DestinationView()
        view.setSelectionSynchronizeKey(key: synchronizeKey)
        return view
    }

    func updateNSView(_ nsView: DestinationView, context: Context) {}
}


// MARK: - Settings view

struct SettingsView: View {

    // Dismissal callback injected by SettingsHostingController.
    var onClose: (() -> Void)?

    // MARK: Connection fields
    @State private var host = ""
    @State private var port = "5001"
    @State private var username = ""
    @State private var password = ""
    @State private var otpEnabled = false
    @State private var otp = ""

    // MARK: Prefs
    @AppStorage("hideDockIcon") private var hideDockIcon = true
    @AppStorage("hideFromStatusBar") private var hideFromStatusBar = false
    @AppStorage("clearFinishedTasks") private var clearFinishedTasks = false

    // MARK: Transient UI state
    @State private var isLoading = false
    @State private var alertItem: AlertItem?

    private struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let isSuccess: Bool
    }

    var body: some View {
        Form {
            connectionSection
            extensionSection
            behaviorSection
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 460)
        .disabled(isLoading)
        .overlay {
            if isLoading {
                ZStack {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                }
            }
        }
        .onAppear(perform: loadStoredCredentials)
        .alert(item: $alertItem) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK")) {
                    if item.isSuccess {
                        onClose?()
                    }
                }
            )
        }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section("NAS Connection") {
            LabeledContent("Host/IP") {
                TextField("", text: $host)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("HTTPS port") {
                TextField("", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
            }
            LabeledContent("Username") {
                TextField("", text: $username)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Password") {
                SecureField("", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("2-step code", isOn: $otpEnabled)
                .onChange(of: otpEnabled) { _, enabled in
                    if !enabled { otp = "" }
                }
            if otpEnabled {
                LabeledContent("Code") {
                    SecureField("", text: $otp)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                }
            }
            Button("Connect and save settings") {
                testConnection()
            }
            .keyboardShortcut(.defaultAction)
            .frame(maxWidth: .infinity)
        }
    }

    private var extensionSection: some View {
        Section("Safari Extension") {
            Text("""
            You can add downloads right from Safari by right-clicking links \
            and choosing "Download with Synology DS Manager". \
            Activate the Safari extension first.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)

            Button("Open in Safari Extensions Preferences…") {
                SFSafariApplication.showPreferencesForExtension(
                    withIdentifier: "com.skavans.synologyDSManager.extension"
                ) { _ in }
            }

            LabeledContent("Extension tasks destination") {
                DestinationViewRepresentable(synchronizeKey: "extension")
                    .frame(width: 230, height: 22)
            }
        }
    }

    private var behaviorSection: some View {
        Section("Behavior") {
            Toggle("Hide Dock icon", isOn: $hideDockIcon)
                .onChange(of: hideDockIcon) { _, hide in
                    applyDockIconPolicy(hide: hide)
                }
            Text("If the Dock icon is hidden, use \"Show window\" in the ↓DS status bar menu.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Toggle("Hide download speed from Status Bar", isOn: $hideFromStatusBar)
            Toggle("Clear finished tasks automatically", isOn: $clearFinishedTasks)
        }
    }

    // MARK: - Actions

    private func loadStoredCredentials() {
        guard let stored = AppModel.shared.loadCredentials() else { return }
        host = stored.host
        port = stored.port
        username = stored.username
        password = stored.password
    }

    private func testConnection() {
        isLoading = true

        let credentials = SynologyAPI.Credentials(
            host: host,
            port: Int(port) ?? 5001,
            username: username,
            password: password,
            otp: otpEnabled && !otp.isEmpty ? otp : nil
        )
        let testAPI = SynologyAPI(
            credentials: credentials,
            trustEvaluator: AppModel.shared.trustEvaluator
        )

        Task { @MainActor in
            defer { isLoading = false }
            do {
                _ = try await testAPI.authenticate()
                let stored = StoredCredentials(
                    host: host,
                    port: port,
                    username: username,
                    password: password,
                    otp: otpEnabled ? otp : ""
                )
                AppModel.shared.saveCredentials(stored)

                if !AppModel.shared.workStarted {
                    AppModel.shared.connect?(stored)
                } else {
                    let newCredentials = SynologyAPI.Credentials(
                        host: host,
                        port: Int(port) ?? 5001,
                        username: username,
                        password: password,
                        otp: otpEnabled && !otp.isEmpty ? otp : nil
                    )
                    do {
                        await AppModel.shared.api?.updateCredentials(newCredentials)
                        _ = try await AppModel.shared.api?.authenticate()
                    } catch {
                        AppLogger.auth.error(
                            "Re-auth after settings change failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }

                alertItem = AlertItem(
                    title: "Success",
                    message: "Connection attempt is successful. Your settings are saved.",
                    isSuccess: true
                )
            } catch {
                alertItem = AlertItem(
                    title: "Error",
                    message: error.localizedDescription,
                    isSuccess: false
                )
            }
        }
    }

    private func applyDockIconPolicy(hide: Bool) {
        if hide {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            mainViewController?.view.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: false)
        }
    }
}


// MARK: - Hosting controller

/// Thin NSHostingController that loads SettingsView from the storyboard
/// slot previously occupied by SettingsViewController. The storyboard's
/// SettingsWC window controller is unchanged; this class just replaces
/// the content view controller it hosts.
final class SettingsHostingController: NSHostingController<SettingsView> {

    required init?(coder: NSCoder) {
        super.init(coder: coder, rootView: SettingsView())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sizingOptions = .preferredContentSize
        rootView = SettingsView { [weak self] in
            self?.view.window?.close()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.styleMask.remove(.fullScreen)
        view.window?.styleMask.remove(.miniaturizable)
        view.window?.styleMask.remove(.resizable)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        NSApplication.shared.activate(ignoringOtherApps: true)
        mainViewController?.view.window?.makeKey()
    }
}
