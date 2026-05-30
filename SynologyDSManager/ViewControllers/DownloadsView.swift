//
//  DownloadsView.swift
//  SynologyDSManager
//
//  SwiftUI replacement for DownloadsViewController (Phase 4, slice 3).
//  DownloadsHostingController owns the NSStatusItem and polling loop;
//  DownloadsView renders the task list and bandwidth footer.
//

import SwiftUI
import UserNotifications


// MARK: - State

@Observable
final class DownloadsState {
    var tasks: [DSMTask] = []
    var bandwidth: Double = 0
    var taskToDelete: DSMTask?

    func update(with newTasks: [DSMTask]) {
        tasks = newTasks
        bandwidth = newTasks.reduce(0.0) { acc, t in
            acc + Double(t.additional?.transfer?.speedDownload ?? 0)
        }
    }
}


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
    let state: DownloadsState

    var body: some View {
        VStack(spacing: 0) {
            if state.tasks.isEmpty {
                Spacer()
                Text("No active downloads")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(state.tasks) { task in
                    DownloadTaskRow(
                        task: task,
                        onStartPause: { toggleTask(task) },
                        onDeleteTap: { state.taskToDelete = task }
                    )
                }
                .listStyle(.plain)
            }

            Divider()

            HStack {
                Text("Bandwidth: \(prettifySpeed(speed: state.bandwidth))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Spacer()
            }
        }
        .alert("Confirm deletion", isPresented: Binding(
            get: { state.taskToDelete != nil },
            set: { if !$0 { state.taskToDelete = nil } }
        )) {
            Button("No", role: .cancel) { state.taskToDelete = nil }
            Button("Yes", role: .destructive) {
                if let t = state.taskToDelete { deleteTask(t) }
                state.taskToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete download \"\(state.taskToDelete?.title ?? "")\"?")
        }
    }

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


// MARK: - Hosting controller

final class DownloadsHostingController: NSHostingController<DownloadsView>,
                                         NSWindowDelegate {

    // MARK: State

    private let dlState: DownloadsState

    private var refreshTask: Task<Void, Never>?
    private var finishedTasks: Set<String> = []
    var statusBarItem: NSStatusItem?

    // MARK: Init

    required init?(coder: NSCoder) {
        let s = DownloadsState()
        self.dlState = s
        super.init(coder: coder, rootView: DownloadsView(state: s))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        mainViewController = self
        AppModel.shared.connect = self.doWork

        initStatusBar()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !(userDefaults.value(forKey: "hideDockIcon") as? Bool ?? true) {
            NSApp.setActivationPolicy(.regular)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.delegate = self
        DispatchQueue.main.async {
            if let settings = AppModel.shared.loadCredentials() {
                self.doWork(settings: settings)
            } else {
                self.settingsMenuItemClicked(self)
            }
        }
    }

    // MARK: NSWindowDelegate — hide instead of close

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.hide(nil)
        return false
    }

    // MARK: Toolbar / menu @objc actions (hit via responder chain from storyboard)

    @objc func settingsMenuItemClicked(_ sender: AnyObject?) {
        showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "SettingsWC")
    }

    @objc func addDownloadMenuItemClicked(_ sender: AnyObject?) {
        showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "addDownloadWC")
    }

    @objc func searchToolbarItemClicked(_ sender: AnyObject?) {
        showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "SearchBTWC")
    }

    @objc func aboutMenuItemClicked(_ sender: AnyObject?) {
        showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "AboutWC")
    }

    @objc func cleanToolbarItemClicked(_ sender: AnyObject?) {
        guard let api = AppModel.shared.api else { return }
        let ids = dlState.tasks.filter(\.isFinished).map(\.id)
        Task { for id in ids { try? await api.deleteTask(id: id) } }
    }

    @objc func resumeAllToolbarItemClicked(_ sender: AnyObject?) {
        guard let api = AppModel.shared.api else { return }
        let ids = dlState.tasks.map(\.id)
        Task { for id in ids { try? await api.resumeTask(id: id) } }
    }

    @objc func pauseAllToolbarItemClicked(_ sender: AnyObject?) {
        guard let api = AppModel.shared.api else { return }
        let ids = dlState.tasks.map(\.id)
        Task { for id in ids { try? await api.pauseTask(id: id) } }
    }

    @objc func clearStateMenuItemClicked(_ sender: AnyObject?) {
        userDefaults.removeObject(forKey: "syno_conn_settings")
    }

    // MARK: Navigation helper (called by DestinationView + AppDelegate)

    func showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: String) {
        guard let wc = storyboard?.instantiateController(
            withIdentifier: storyboardWindowControllerIdentifier
        ) as? NSWindowController,
              let window = wc.window,
              let mainWindow = view.window else { return }

        let frame = mainWindow.frame
        window.setFrameTopLeftPoint(NSPoint(
            x: frame.midX - window.frame.width / 2,
            y: frame.midY + window.frame.height / 2
        ))
        wc.showWindow(self)
        currentViewController = wc.contentViewController
    }

    // MARK: Extension URL handler

    func downloadByURLFromExtension(URL url: String) {
        guard let api = AppModel.shared.api else { return }
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

    // MARK: Polling loop

    func doWork(settings: StoredCredentials) {
        refreshTask?.cancel()
        refreshTask = nil

        let newAPI = SynologyAPI(
            credentials: settings.apiCredentials,
            trustEvaluator: AppModel.shared.trustEvaluator
        )
        AppModel.shared.setAPI(newAPI)
        guard let api = AppModel.shared.api else { return }

        start_webserver()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await api.authenticate()
            } catch {
                AppLogger.auth.error(
                    "SynologyAPI auth failed: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
            while !Task.isCancelled {
                await self.refreshDownloads(api: api)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }

        AppModel.shared.markWorkStarted()
    }

    @MainActor
    private func refreshDownloads(api: SynologyAPI) async {
        let newTasks: [DSMTask]
        do {
            newTasks = try await api.listTasks()
        } catch {
            AppLogger.network.error("listTasks failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        let isFirst = dlState.tasks.isEmpty && finishedTasks.isEmpty
        for task in newTasks where task.isFinished {
            if !finishedTasks.contains(task.title) {
                if !isFirst { notifyFinished(title: task.title) }
                finishedTasks.insert(task.title)
            }
            if userDefaults.bool(forKey: "clearFinishedTasks") {
                let id = task.id
                Task { try? await api.deleteTask(id: id) }
            }
        }

        dlState.update(with: newTasks)

        let speed = prettifySpeed(speed: dlState.bandwidth)
        statusBarItem?.button?.title = userDefaults.bool(forKey: "hideFromStatusBar")
            ? "↓DS"
            : "↓DS: \(speed)"
    }

    // MARK: Notifications

    private func notifyFinished(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Task finished"
        content.body = title
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        )
    }

    // MARK: Status bar

    @objc func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(self)
    }

    private func initStatusBar() {
        let bar = NSStatusBar.system
        statusBarItem = bar.statusItem(withLength: NSStatusItem.variableLength)
        statusBarItem?.button?.title = userDefaults.bool(forKey: "hideFromStatusBar")
            ? "↓DS"
            : "↓DS: 0.0 B/s"

        let menu = NSMenu(title: "Synology DS Manager Status Bar Menu")
        menu.addItem(NSMenuItem.separator())

        let pauseItem = NSMenuItem(title: "Pause all",
                                   action: #selector(pauseAllToolbarItemClicked), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let startItem = NSMenuItem(title: "Start all",
                                   action: #selector(resumeAllToolbarItemClicked), keyEquivalent: "")
        startItem.target = self
        menu.addItem(startItem)

        let cleanItem = NSMenuItem(title: "Clear finished",
                                   action: #selector(cleanToolbarItemClicked), keyEquivalent: "")
        cleanItem.target = self
        menu.addItem(cleanItem)

        menu.addItem(NSMenuItem.separator())

        let showItem = NSMenuItem(title: "Show window",
                                  action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)

        menu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About",
                                   action: #selector(aboutMenuItemClicked), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quitApp), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        statusBarItem?.menu = menu
    }
}
