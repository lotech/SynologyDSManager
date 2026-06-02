//
//  SettingsView.swift
//  SynologyDSManager
//

import SwiftUI
import SafariServices.SFSafariApplication


// MARK: - Row helpers

private struct FieldRow<Control: View>: View {
    let label: String
    let control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 90, alignment: .trailing)
                .foregroundStyle(.secondary)
            control
        }
    }
}

private struct SectionTitle: View {
    let title: String
    var trailing: String?

    init(title: String, trailing: String? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.headline)
            if let trailing {
                Text(trailing)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// A titled settings block: leading-aligned, consistent inner spacing,
/// uniform padding. Keeps every section visually identical.
private struct SettingsSection<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}


// MARK: - Settings view

struct SettingsView: View {

    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "5001"
    @State private var username = ""
    @State private var password = ""
    @State private var otpEnabled = false
    @State private var otp = ""

    @AppStorage("hideDockIcon")          private var hideDockIcon = true
    @AppStorage("hideFromStatusBar")     private var hideFromStatusBar = false
    @AppStorage("clearFinishedTasks")    private var clearFinishedTasks = false

    @State private var isLoading = false
    @State private var alertItem: AlertItem?

    private struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let isSuccess: Bool
    }

    var body: some View {
        ZStack {
            content
            if isLoading {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .frame(width: 400)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear(perform: loadStoredCredentials)
        .disabled(isLoading)
        .alert(item: $alertItem) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text("OK")) {
                    if item.isSuccess { dismiss() }
                }
            )
        }
    }

    // MARK: - Content layout

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── NAS Connection ──────────────────────────────────
            SettingsSection {
                SectionTitle(title: "NAS Connection")

                FieldRow("Host/IP") {
                    TextField("192.168.x.x or hostname", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                FieldRow("HTTPS port") {
                    TextField("5001", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                    Spacer()
                }
                FieldRow("Username") {
                    TextField("", text: $username)
                        .textFieldStyle(.roundedBorder)
                }
                FieldRow("Password") {
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                }

                Toggle("2-step verification code", isOn: $otpEnabled)
                    .padding(.leading, 98)
                    .onChange(of: otpEnabled) { _, enabled in
                        if !enabled { otp = "" }
                    }

                if otpEnabled {
                    FieldRow("Code") {
                        SecureField("6-digit code", text: $otp)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                        Spacer()
                    }
                }

                Button("Connect and save settings", action: testConnection)
                    .keyboardShortcut(.defaultAction)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }

            Divider()

            // ── Safari Extension ────────────────────────────────
            // Disabled for now: the Web Extension's service worker won't
            // start on current Safari (Phase 3b-2b-RT blocker), so the
            // whole section is greyed out until the bridge is shippable.
            SettingsSection {
                SectionTitle(title: "Safari Extension", trailing: "Coming soon")

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "safari")
                        .foregroundStyle(.secondary)
                    Text("Right-click any link in Safari and choose \"Download with Synology DS Manager\".")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button("Open Safari Extension Preferences…") {
                    SFSafariApplication.showPreferencesForExtension(
                        withIdentifier: "com.skavans.synologyDSManager.extension"
                    ) { _ in }
                }

                FieldRow("Destination") {
                    DestinationPicker(synchronizeKey: "extension")
                        .frame(width: 220)
                    Spacer()
                }
            }
            .disabled(true)
            .opacity(0.45)

            Divider()

            // ── Behavior ────────────────────────────────────────
            SettingsSection {
                SectionTitle(title: "Behavior")

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Hide Dock icon", isOn: $hideDockIcon)
                        .onChange(of: hideDockIcon) { _, hide in applyDockIconPolicy(hide: hide) }
                    Text("Use \"Show window\" in the ↓DS status bar menu to bring the window back.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                }

                Toggle("Hide download speed from status bar", isOn: $hideFromStatusBar)
                Toggle("Clear finished tasks automatically", isOn: $clearFinishedTasks)
            }
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
        let testAPI = SynologyAPI(credentials: credentials, trustEvaluator: AppModel.shared.trustEvaluator)

        Task { @MainActor in
            defer { isLoading = false }
            do {
                _ = try await testAPI.authenticate()
                let stored = StoredCredentials(
                    host: host, port: port, username: username, password: password,
                    otp: otpEnabled ? otp : ""
                )
                AppModel.shared.saveCredentials(stored)

                if !AppModel.shared.workStarted {
                    AppModel.shared.startPolling(credentials: stored)
                } else {
                    let updated = SynologyAPI.Credentials(
                        host: host, port: Int(port) ?? 5001,
                        username: username, password: password,
                        otp: otpEnabled && !otp.isEmpty ? otp : nil
                    )
                    do {
                        await AppModel.shared.api?.updateCredentials(updated)
                        _ = try await AppModel.shared.api?.authenticate()
                    } catch {
                        AppLogger.auth.error(
                            "Re-auth after settings change failed: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
                alertItem = AlertItem(
                    title: "Success",
                    message: "Connection successful. Settings saved.",
                    isSuccess: true
                )
            } catch {
                alertItem = AlertItem(title: "Error", message: error.localizedDescription, isSuccess: false)
            }
        }
    }

    private func applyDockIconPolicy(hide: Bool) {
        if hide {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: false)
        }
    }
}
