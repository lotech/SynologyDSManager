//
//  DownloadsView.swift
//  SynologyDSManager
//

import SwiftUI
import UserNotifications


// MARK: - Task row

private struct DownloadTaskRow: View {
    let task: DSMTask
    let onStartPause: () -> Void
    let onDeleteTap: () -> Void

    private var progress: Double {
        let total = Double(task.size)
        guard total > 0 else { return 0 }
        let done = Double(task.additional?.transfer?.sizeDownloaded ?? 0)
        return done / total * 100
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: progress, total: 100)
                    .progressViewStyle(.linear)
                HStack {
                    let done = Double(task.additional?.transfer?.sizeDownloaded ?? 0)
                    let total = Double(task.size)
                    Text("\(prettifyBytesCount(bytesCount: done)) of \(prettifyBytesCount(bytesCount: total)) (\(Int(progress))%)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    let speed = Double(task.additional?.transfer?.speedDownload ?? 0)
                    Text("\(task.status) · \(prettifySpeed(speed: speed))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onStartPause) {
                Image(nsImage: startPauseImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .disabled(task.isFinished)

            Button(action: onDeleteTap) {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private var startPauseImage: NSImage {
        if task.isPaused {
            return NSImage(named: "NSTouchBarPlayTemplate") ?? NSImage()
        } else if task.isDownloading {
            return NSImage(named: "NSTouchBarPauseTemplate") ?? NSImage()
        } else {
            return NSImage(named: "NSStatusNoneTemplate") ?? NSImage()
        }
    }
}


// MARK: - Main view

struct DownloadsView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var taskToDelete: DSMTask?

    var body: some View {
        taskContent
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bandwidthFooter
            }
            .alert("Confirm deletion", isPresented: Binding(
                get: { taskToDelete != nil },
                set: { if !$0 { taskToDelete = nil } }
            )) {
                Button("No", role: .cancel) { taskToDelete = nil }
                Button("Yes", role: .destructive) {
                    if let t = taskToDelete { deleteTask(t) }
                    taskToDelete = nil
                }
            } message: {
                Text("Are you sure you want to delete download \"\(taskToDelete?.title ?? "")\"?")
            }
            .toolbar { toolbarContent }
            .task { onViewAppear() }
            .onChange(of: AppModel.shared.pendingTorrentPaths) { _, paths in
                if !paths.isEmpty { openWindow(id: "add-download") }
            }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button { openWindow(id: "settings") } label: {
                Label("Settings", systemImage: "gear")
            }
            .help("Settings")
        }
        ToolbarItem(placement: .automatic) {
            Button { openWindow(id: "add-download") } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add download")
        }
        ToolbarItem(placement: .automatic) {
            Button { openWindow(id: "bt-search") } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search BitTorrent")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await AppModel.shared.pauseAll() } } label: {
                Label("Pause all", systemImage: "pause.fill")
            }
            .help("Pause all downloads")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await AppModel.shared.resumeAll() } } label: {
                Label("Start all", systemImage: "play.fill")
            }
            .help("Resume all downloads")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { Task { await AppModel.shared.clearFinished() } } label: {
                Label("Clear finished", systemImage: "eraser.fill")
            }
            .help("Clear finished downloads")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var taskContent: some View {
        if AppModel.shared.tasks.isEmpty {
            Text("No active downloads")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(AppModel.shared.tasks) { task in
                DownloadTaskRow(
                    task: task,
                    onStartPause: { toggleTask(task) },
                    onDeleteTap: { taskToDelete = task }
                )
            }
            .listStyle(.plain)
        }
    }

    private var bandwidthFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("Bandwidth: \(prettifySpeed(speed: AppModel.shared.bandwidth))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Spacer()
            }
            .background(.bar)
        }
    }

    // MARK: - Launch logic

    private func onViewAppear() {
        // Consume any torrent paths that arrived before the view appeared.
        if !AppModel.shared.pendingTorrentPaths.isEmpty {
            openWindow(id: "add-download")
        }

        // Open Settings on first launch when no credentials are configured.
        guard !AppModel.shared.workStarted else { return }
        if AppModel.shared.loadCredentials() == nil {
            openWindow(id: "settings")
        }
    }

    // MARK: - Task actions

    private func toggleTask(_ task: DSMTask) {
        guard let api = AppModel.shared.api else { return }
        Task {
            if task.isPaused {
                try? await api.resumeTask(id: task.id)
            } else if task.isDownloading {
                try? await api.pauseTask(id: task.id)
            }
        }
    }

    private func deleteTask(_ task: DSMTask) {
        guard let api = AppModel.shared.api else { return }
        Task { try? await api.deleteTask(id: task.id) }
    }
}
