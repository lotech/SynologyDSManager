//
//  DownloadsView.swift
//  SynologyDSManager
//

import SwiftUI
import AppKit
import UserNotifications


// MARK: - DSMTask sort/display helpers

extension DSMTask {
    var downloadedBytes: Int64 { additional?.transfer?.sizeDownloaded ?? 0 }
    var downloadSpeed: Int64 { additional?.transfer?.speedDownload ?? 0 }

    /// 0…1 completion fraction, used for the progress column and sorting.
    var fractionComplete: Double {
        guard size > 0 else { return 0 }
        return min(1, Double(downloadedBytes) / Double(size))
    }
}


// MARK: - Sort persistence

/// Maps the Table's `KeyPathComparator` to/from a small persisted form
/// (`UserDefaults`). In-session sorting is driven directly by the Table's
/// `sortOrder` binding; this only records the choice so it survives a relaunch.
private enum DownloadSort {
    static func comparator(field: String, ascending: Bool) -> KeyPathComparator<DSMTask> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch field {
        case "progress": return KeyPathComparator(\DSMTask.fractionComplete, order: order)
        case "size":     return KeyPathComparator(\DSMTask.size, order: order)
        case "status":   return KeyPathComparator(\DSMTask.status, order: order)
        case "speed":    return KeyPathComparator(\DSMTask.downloadSpeed, order: order)
        default:         return KeyPathComparator(\DSMTask.title, order: order) // "name"
        }
    }

    static func field(for keyPath: AnyKeyPath) -> String {
        if keyPath == \DSMTask.fractionComplete { return "progress" }
        if keyPath == \DSMTask.size { return "size" }
        if keyPath == \DSMTask.status { return "status" }
        if keyPath == \DSMTask.downloadSpeed { return "speed" }
        return "name"
    }
}


// MARK: - Progress cell

private struct ProgressCell: View {
    let task: DSMTask

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: task.fractionComplete)
                .progressViewStyle(.linear)
            Text("\(Int(task.fractionComplete * 100))%")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}


// MARK: - Main view

struct DownloadsView: View {
    @Environment(\.openWindow) private var openWindow

    @State private var selection: Set<DSMTask.ID> = []
    @State private var sortOrder: [KeyPathComparator<DSMTask>] = [
        KeyPathComparator(\DSMTask.title, order: .forward)
    ]
    @State private var deleteCandidates: [DSMTask] = []

    @AppStorage("downloadsSortField")     private var savedSortField = "name"
    @AppStorage("downloadsSortAscending") private var savedSortAscending = true

    private var sortedTasks: [DSMTask] {
        AppModel.shared.tasks.sorted(using: sortOrder)
    }

    var body: some View {
        taskContent
            .safeAreaInset(edge: .bottom, spacing: 0) { bandwidthFooter }
            .alert("Confirm deletion", isPresented: Binding(
                get: { !deleteCandidates.isEmpty },
                set: { if !$0 { deleteCandidates = [] } }
            )) {
                Button("Cancel", role: .cancel) { deleteCandidates = [] }
                Button("Delete", role: .destructive) {
                    performDelete(deleteCandidates)
                    deleteCandidates = []
                }
            } message: {
                Text(deleteMessage)
            }
            .toolbar { toolbarContent }
            .task { onViewAppear() }
            .onAppear {
                sortOrder = [DownloadSort.comparator(field: savedSortField, ascending: savedSortAscending)]
            }
            .onChange(of: sortOrder) { _, new in
                guard let first = new.first else { return }
                savedSortField = DownloadSort.field(for: first.keyPath)
                savedSortAscending = first.order == .forward
            }
            .onChange(of: AppModel.shared.pendingTorrentPaths) { _, paths in
                if !paths.isEmpty { openWindow(id: "add-download") }
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
            Table(sortedTasks, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.title) { task in
                    Text(task.title).truncationMode(.middle)
                }
                .width(min: 140, ideal: 220)

                TableColumn("Progress", value: \.fractionComplete) { task in
                    ProgressCell(task: task)
                }
                .width(min: 90, ideal: 130)

                TableColumn("Size", value: \.size) { task in
                    Text(prettifyBytesCount(bytesCount: Double(task.size)))
                        .monospacedDigit()
                }
                .width(min: 64, ideal: 80)

                TableColumn("Status", value: \.status) { task in
                    Text(task.status.capitalized)
                }
                .width(min: 70, ideal: 90)

                TableColumn("Speed", value: \.downloadSpeed) { task in
                    Text(prettifySpeed(speed: Double(task.downloadSpeed)))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 90)
            }
            .contextMenu(forSelectionType: DSMTask.ID.self) { ids in
                contextMenu(for: ids)
            } primaryAction: { ids in
                togglePauseResume(ids)
            }
            .onDeleteCommand { requestDelete(selection) }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<DSMTask.ID>) -> some View {
        Button("Resume") { resume(ids) }
        Button("Pause") { pause(ids) }
        if ids.count == 1,
           let uri = tasks(for: ids).first?.additional?.detail?.uri, !uri.isEmpty {
            Divider()
            Button("Copy Link") { copyToPasteboard(uri) }
        }
        Divider()
        Button("Delete", role: .destructive) { requestDelete(ids) }
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

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Settings sits on the leading edge, set apart from the
        // download actions grouped on the trailing edge.
        ToolbarItem(placement: .navigation) {
            Button { openWindow(id: "settings") } label: {
                Label("Settings", systemImage: "gear")
            }
            .help("Settings")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { openWindow(id: "add-download") } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add download")
        }
        ToolbarItem(placement: .primaryAction) {
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

    private func tasks(for ids: Set<DSMTask.ID>) -> [DSMTask] {
        AppModel.shared.tasks.filter { ids.contains($0.id) }
    }

    /// Double-click / Return: pause running items, resume paused ones. If the
    /// targeted set is mixed, pause wins (stop first, ask later).
    private func togglePauseResume(_ ids: Set<DSMTask.ID>) {
        let targets = tasks(for: ids)
        guard !targets.isEmpty else { return }
        if targets.contains(where: { $0.isDownloading }) {
            pause(ids)
        } else {
            resume(ids)
        }
    }

    private func pause(_ ids: Set<DSMTask.ID>) {
        guard let api = AppModel.shared.api else { return }
        Task { for id in ids { try? await api.pauseTask(id: id) } }
    }

    private func resume(_ ids: Set<DSMTask.ID>) {
        guard let api = AppModel.shared.api else { return }
        Task { for id in ids { try? await api.resumeTask(id: id) } }
    }

    private func requestDelete(_ ids: Set<DSMTask.ID>) {
        let targets = tasks(for: ids)
        guard !targets.isEmpty else { return }
        deleteCandidates = targets
    }

    private func performDelete(_ targets: [DSMTask]) {
        guard let api = AppModel.shared.api else { return }
        let ids = targets.map(\.id)
        selection.subtract(ids)
        Task { for id in ids { try? await api.deleteTask(id: id) } }
    }

    private func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var deleteMessage: String {
        if deleteCandidates.count == 1 {
            return "Are you sure you want to delete download \"\(deleteCandidates[0].title)\"?"
        }
        return "Are you sure you want to delete \(deleteCandidates.count) downloads?"
    }
}
