//
//  AddDownloadView.swift
//  SynologyDSManager
//

import SwiftUI
import UniformTypeIdentifiers


// MARK: - State

@Observable
final class AddDownloadState {
    var taskText: String = ""
    var isSubmitting = false
    var failureAlert: String?

    var torrents: [String] { parsed.0 }
    var urls: [String] { parsed.1 }
    var isValid: Bool { let (t, u) = parsed; return !t.isEmpty || !u.isEmpty }

    private var parsed: ([String], [String]) {
        var torrents: [String] = []
        var urls: [String] = []
        for line in taskText.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("/") && trimmed.hasSuffix(".torrent") {
                torrents.append(trimmed)
            } else if trimmed.hasPrefix("http") || trimmed.hasPrefix("ftp") ||
                      trimmed.hasPrefix("ed2k") || trimmed.hasPrefix("magnet") {
                urls.append(trimmed)
            }
        }
        return (torrents, urls)
    }
}


// MARK: - View

struct AddDownloadView: View {
    @Bindable var state: AddDownloadState
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $state.taskText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                if state.taskText.isEmpty {
                    Text("Enter URLs or torrent file paths, one per line")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            Divider()

            DestinationPicker(synchronizeKey: "main")
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

            Divider()

            HStack {
                Button("Choose Torrent File…") { chooseTorrentFile() }
                    .disabled(state.isSubmitting)
                Spacer()
                if state.isSubmitting {
                    ProgressView().controlSize(.small)
                }
                Button(downloadButtonTitle, action: startDownload)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.isValid || state.isSubmitting)
            }
            .padding(12)
        }
        .frame(width: 420)
        .alert("Some downloads couldn't be added", isPresented: Binding(
            get: { state.failureAlert != nil },
            set: { if !$0 { state.failureAlert = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.failureAlert ?? "")
        }
    }

    private var downloadButtonTitle: String {
        guard state.isValid else { return "Add at least one URL or torrent-file" }
        return "Download \(state.torrents.count) torrents and \(state.urls.count) URLs"
    }

    private func chooseTorrentFile() {
        let dialog = NSOpenPanel()
        dialog.title = "Choose one or multiple torrent-files"
        dialog.showsResizeIndicator = true
        dialog.showsHiddenFiles = false
        dialog.canChooseDirectories = false
        dialog.canCreateDirectories = false
        dialog.allowsMultipleSelection = true
        if let torrentType = UTType(filenameExtension: "torrent") {
            dialog.allowedContentTypes = [torrentType]
        }
        guard dialog.runModal() == .OK else { return }
        let newPaths = dialog.urls.map { "\($0.path)\n" }.joined()
        state.taskText = newPaths + state.taskText
    }

    private func startDownload() {
        guard let api = AppModel.shared.api else { onClose(); return }
        let torrentPaths = state.torrents
        let urlStrings = state.urls
        let destination = userDefaults.string(forKey: "destinationSelectedPath_main")
        state.isSubmitting = true

        // Keep the window open until the NAS responds so failures can be
        // surfaced. The successfully-added items drop out; any that failed
        // stay in the field for retry, alongside an alert explaining why.
        Task { @MainActor in
            var failures: [(line: String, error: String)] = []
            for path in torrentPaths {
                do {
                    try await api.createTask(torrentFile: URL(fileURLWithPath: path), destination: destination)
                } catch {
                    failures.append((path, error.localizedDescription))
                    AppLogger.network.error(
                        "createTask(torrentFile:) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            for url in urlStrings {
                do {
                    try await api.createTask(url: url, destination: destination)
                } catch {
                    failures.append((url, error.localizedDescription))
                    AppLogger.network.error(
                        "createTask(url:) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            state.isSubmitting = false
            if failures.isEmpty {
                state.taskText = ""
                onClose()
            } else {
                state.taskText = failures.map(\.line).joined(separator: "\n")
                state.failureAlert = failures
                    .map { "• \($0.line)\n    \($0.error)" }
                    .joined(separator: "\n\n")
            }
        }
    }
}
