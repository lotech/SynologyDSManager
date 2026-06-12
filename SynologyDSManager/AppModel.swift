//
//  AppModel.swift
//  SynologyDSManager
//

import Foundation
import AppKit
import Observation
import UserNotifications


@Observable
@MainActor
final class AppModel {

    // MARK: - Singleton

    static let shared = AppModel()
    private init() {}

    // MARK: - App-wide singletons

    private(set) var api: SynologyAPI?
    let trustEvaluator = SynologyTrustEvaluator()

    // MARK: - Live state (observed by views)

    var tasks: [DSMTask] = []
    var bandwidth: Double = 0

    /// Text shown in the MenuBarExtra label (↓DS / ↓DS: X.X MB/s).
    var statusBarTitle: String = UserDefaults.standard.bool(forKey: "hideFromStatusBar")
        ? "↓DS"
        : "↓DS: 0.0 B/s"

    // MARK: - Pending items from URL/file open events

    /// Torrent file paths set by AppDelegate; consumed by AddDownloadRootView.
    var pendingTorrentPaths: [String] = []

    /// External download URL set by AppDelegate; consumed by DownloadsView.
    var pendingExternalURL: String?

    // MARK: - Connection lifecycle

    private(set) var workStarted = false
    private var pollingTask: Task<Void, Never>?
    private var finishedTaskTitles: Set<String> = []

    // MARK: - Polling

    func startPolling(credentials: StoredCredentials) {
        pollingTask?.cancel()

        let newAPI = SynologyAPI(credentials: credentials.apiCredentials, trustEvaluator: trustEvaluator)
        api = newAPI

        start_webserver()

        pollingTask = Task { [weak self] in
            guard let self else { return }
            guard let api = self.api else { return }
            do {
                _ = try await api.authenticate()
            } catch {
                AppLogger.auth.error(
                    "SynologyAPI auth failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            while !Task.isCancelled {
                await self.refreshDownloads()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        workStarted = true
    }

    @MainActor
    private func refreshDownloads() async {
        guard let api else { return }
        let newTasks: [DSMTask]
        do {
            newTasks = try await api.listTasks()
        } catch {
            AppLogger.network.error("listTasks failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let isFirst = tasks.isEmpty && finishedTaskTitles.isEmpty
        for task in newTasks where task.isFinished {
            if !finishedTaskTitles.contains(task.title) {
                if !isFirst { notifyFinished(title: task.title) }
                finishedTaskTitles.insert(task.title)
            }
            if userDefaults.bool(forKey: "clearFinishedTasks") {
                let id = task.id
                Task { try? await api.deleteTask(id: id) }
            }
        }

        tasks = newTasks
        bandwidth = newTasks.reduce(0.0) { acc, t in
            acc + Double(t.additional?.transfer?.speedDownload ?? 0)
        }

        let speed = prettifySpeed(speed: bandwidth)
        statusBarTitle = userDefaults.bool(forKey: "hideFromStatusBar")
            ? "↓DS"
            : "↓DS: \(speed)"

        updateDockBadge(finishedCount: newTasks.filter(\.isFinished).count)
    }

    /// Show the number of finished downloads on the Dock icon (only visible
    /// when the Dock icon itself is shown — i.e. "Hide Dock icon" is off).
    private func updateDockBadge(finishedCount: Int) {
        NSApp.dockTile.badgeLabel = finishedCount > 0 ? String(finishedCount) : nil
    }

    // MARK: - Bulk task actions

    func pauseAll() async {
        guard let api else { return }
        for id in tasks.map(\.id) { try? await api.pauseTask(id: id) }
    }

    func resumeAll() async {
        guard let api else { return }
        for id in tasks.map(\.id) { try? await api.resumeTask(id: id) }
    }

    func clearFinished() async {
        guard let api else { return }
        for id in tasks.filter(\.isFinished).map(\.id) { try? await api.deleteTask(id: id) }
    }

    // MARK: - Extension / URL-scheme download

    func enqueueDownload(url: String) {
        guard let api else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download started"
        content.subtitle = "URL content is downloading at Synology DS"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
        let destination = userDefaults.string(forKey: "destinationSelectedPath_extension")
        Task.detached { [api] in
            do {
                try await api.createTask(url: url, destination: destination)
            } catch {
                AppLogger.network.error(
                    "createTask(url:) from extension failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Notifications

    private func notifyFinished(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Task finished"
        content.body = title
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: - Credential persistence

    func loadCredentials() -> StoredCredentials? {
        readSettings()
    }

    func saveCredentials(_ credentials: StoredCredentials) {
        storeSettings(credentials)
    }
}
