//
//  DownloadsViewController.swift
//  SynologyDSManager
//

import Cocoa
import Foundation
import UserNotifications


class DownloadsViewController: NSViewController, NSWindowDelegate {

    // MARK: - State

    /// Tasks currently displayed. Mirrors what `SynologyAPI.listTasks()`
    /// last returned; empty before the first successful fetch.
    private var tasks: [DSMTask] = []

    /// Titles of tasks we've previously observed in the `.finished`
    /// state. Used to avoid re-notifying the user about the same
    /// finished download on every 3-second tick.
    private var finishedTasks: Set<String> = []

    /// The async polling loop started in `doWork`. Stored so a repeat
    /// call into `doWork` (e.g. from a credentials change) can cancel
    /// the previous loop before starting a new one.
    private var refreshTask: Task<Void, Never>?

    var statusBarItem: NSStatusItem? = nil

    @IBOutlet weak var downloadsTableView: NSTableView!
    @IBOutlet weak var bandwidthLabel: NSTextField!
    @IBOutlet weak var downloadsPlaceholderLabel: NSTextField!

    // MARK: - Window lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.hide(nil)
        return false
    }

    // MARK: - Menu / toolbar actions

    @IBAction func settingsMenuItemClicked(_ sender: AnyObject?) {
        self.showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "SettingsWC")
    }

    @IBAction func addDownloadMenuItemClicked(_ sender: AnyObject?) {
        self.showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "addDownloadWC")
    }

    @IBAction func searchToolbarItemClicked(_ sender: AnyObject?) {
        self.showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "SearchBTWC")
    }

    @IBAction func cleanToolbarItemClicked(_ sender: AnyObject?) {
        guard let api = synologyAPI else { return }
        let finishedIDs = tasks.filter(\.isFinished).map(\.id)
        Task {
            for id in finishedIDs {
                try? await api.deleteTask(id: id)
            }
        }
    }

    @IBAction func resumeAllToolbarItemClicked(_ sender: AnyObject?) {
        guard let api = synologyAPI else { return }
        let ids = tasks.map(\.id)
        Task {
            for id in ids {
                try? await api.resumeTask(id: id)
            }
        }
    }

    @IBAction func pauseAllToolbarItemClicked(_ sender: AnyObject?) {
        guard let api = synologyAPI else { return }
        let ids = tasks.map(\.id)
        Task {
            for id in ids {
                try? await api.pauseTask(id: id)
            }
        }
    }

    @IBAction func aboutMenuItemClicked(_ sender: AnyObject?) {
        self.showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: "AboutWC")
    }

    @IBAction func clearStateMenuItemClicked(_ sender: AnyObject?) {
        userDefaults.removeObject(forKey: "syno_conn_settings")
    }

    public func showStoryboardWindowCenteredToMainWindow(storyboardWindowControllerIdentifier: String) {
        let windowController = self.storyboard?.instantiateController(withIdentifier: storyboardWindowControllerIdentifier) as! NSWindowController
        let window = windowController.window!
        let mainWindow = self.view.window!
        let frame = mainWindow.frame
        let newLeft = frame.midX - window.frame.width / 2
        let newTop = frame.midY + window.frame.height / 2
        window.setFrameTopLeftPoint(NSPoint(x: newLeft, y: newTop))
        windowController.showWindow(self)
        currentViewController = windowController.contentViewController
    }

    // MARK: - Notifications

    private func notificateTaskFinished(title: String) {
        let content = UNMutableNotificationContent()
        content.title = "Task finished"
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // MARK: - Refresh

    /// Fetch the latest task list once and render it. Errors are logged
    /// but do not propagate; the next tick will retry. Main-actor-isolated
    /// because everything it touches (the table view, the status bar, the
    /// placeholder label) is UI.
    @MainActor
    private func refreshDownloads() async {
        guard let api = synologyAPI else { return }

        let newTasks: [DSMTask]
        do {
            newTasks = try await api.listTasks()
        } catch {
            AppLogger.network.error("listTasks failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Suppress "task finished" notifications on the very first
        // response: the user may have a NAS full of already-finished
        // historical tasks we don't want to announce retroactively.
        let isFirstDataReceived = tasks.isEmpty && finishedTasks.isEmpty

        for task in newTasks where task.isFinished {
            if !finishedTasks.contains(task.title) {
                if !isFirstDataReceived {
                    notificateTaskFinished(title: task.title)
                }
                finishedTasks.insert(task.title)
            }
            if userDefaults.bool(forKey: "clearFinishedTasks") {
                let id = task.id
                Task { try? await api.deleteTask(id: id) }
            }
        }

        tasks = newTasks
        downloadsPlaceholderLabel.isHidden = !newTasks.isEmpty

        let bandwidth = newTasks.reduce(Int64(0)) { acc, task in
            acc + (task.additional?.transfer?.speedDownload ?? 0)
        }
        bandwidthLabel.stringValue = "Bandwidth: \(prettifySpeed(speed: Double(bandwidth)))"
        statusBarItem?.button?.title = userDefaults.bool(forKey: "hideFromStatusBar")
            ? "↓DS"
            : "↓DS: \(prettifySpeed(speed: Double(bandwidth)))"

        downloadsTableView.reloadData()
    }

    // MARK: - Setup

    private func doWork(settings: SynologyClient.ConnectionSettings) {
        // Cancel any previous refresh loop. Defensive: with `workStarted`
        // being set below, a repeat Test Connection takes the else-branch
        // in SettingsViewController and doesn't re-enter doWork. This
        // guard just means the second call is cheap if it ever happens.
        refreshTask?.cancel()
        refreshTask = nil

        synologyClient = SynologyClient(settings: settings)

        let port = Int(settings.port) ?? 5001
        synologyAPI = SynologyAPI(
            credentials: SynologyAPI.Credentials(
                host: settings.host,
                port: port,
                username: settings.username,
                password: settings.password,
                otp: settings.otp.isEmpty ? nil : settings.otp
            ),
            trustEvaluator: synologyTrustEvaluator
        )

        // Capture the instance we just assigned to the global so the
        // refresh loop below holds a stable reference, independent of
        // any later reassignment of the `synologyAPI` global (e.g. if
        // Settings changes credentials during a re-auth — we want the
        // currently-running loop to keep using the current client).
        guard let api = synologyAPI else { return }

        start_webserver()

        // Legacy SynologyClient still drives Add / Search / ChooseDest
        // (migrated in Phase 2a-2c). Authenticate it so those screens
        // work; if it fails, log and continue — the downloads list
        // below is now independent of it.
        synologyClient?.authenticate { ok, err in
            if !ok {
                AppLogger.auth.error(
                    "Legacy SynologyClient auth failed in doWork: \(err?.localizedDescription ?? "unknown", privacy: .public)"
                )
            }
        }

        // Modern refresh loop on SynologyAPI. Authenticates once, then
        // polls listTasks every 3 seconds until cancelled. Cancellation
        // happens when doWork is called again or the app quits.
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await api.authenticate()
            } catch {
                AppLogger.auth.error(
                    "SynologyAPI auth in refresh loop failed: \(error.localizedDescription, privacy: .public)"
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

    public func downloadByURLFromExtension(URL: String) {
        registerEvent(type: "firstExtensionUse", unique: true)
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = "Download started"
            content.subtitle = "URL content is downloading at Synology DS"
            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            let extensionDestination = userDefaults.string(forKey: "destinationSelectedPath_extension")
            synologyClient?.startDownload(URL: URL, destination: extensionDestination)
        }
    }

    // MARK: - Status bar

    @objc func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quit() {
        NSApplication.shared.terminate(self)
    }

    func initStatusBar() {
        let statusBar = NSStatusBar.system
        statusBarItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
        statusBarItem!.button?.title = userDefaults.bool(forKey: "hideFromStatusBar") ? "↓DS" : "↓DS: 0.0 B/s"

        let statusBarMenu = NSMenu(title: "Synology DS Manager Status Bar Menu")
        statusBarItem?.menu = statusBarMenu

        statusBarMenu.addItem(NSMenuItem.separator())

        let pauseAllItem = NSMenuItem(title: "Pause all", action: #selector(pauseAllToolbarItemClicked), keyEquivalent: "")
        pauseAllItem.target = self
        statusBarMenu.addItem(pauseAllItem)

        let startAllItem = NSMenuItem(title: "Start all", action: #selector(resumeAllToolbarItemClicked), keyEquivalent: "")
        startAllItem.target = self
        statusBarMenu.addItem(startAllItem)

        let cleanItem = NSMenuItem(title: "Clear finished", action: #selector(cleanToolbarItemClicked), keyEquivalent: "")
        cleanItem.target = self
        statusBarMenu.addItem(cleanItem)

        statusBarMenu.addItem(NSMenuItem.separator())

        let showWindowItem = NSMenuItem(title: "Show window", action: #selector(showWindow), keyEquivalent: "")
        showWindowItem.target = self
        statusBarMenu.addItem(showWindowItem)

        statusBarMenu.addItem(NSMenuItem.separator())

        let aboutItem = NSMenuItem(title: "About", action: #selector(aboutMenuItemClicked), keyEquivalent: "")
        aboutItem.target = self
        statusBarMenu.addItem(aboutItem)

        statusBarMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "")
        quitItem.target = self
        statusBarMenu.addItem(quitItem)
    }

    // MARK: - View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        registerEvent(type: "firstOpen", unique: true)

        mainViewController = self
        mainMethod = self.doWork

        downloadsTableView.delegate = self
        downloadsTableView.dataSource = self

        self.initStatusBar()

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        if !(userDefaults.value(forKey: "hideDockIcon") as? Bool ?? true) {
            NSApp.setActivationPolicy(.regular)
        }
    }

    override func viewDidAppear() {
        self.view.window!.delegate = self
        DispatchQueue.main.async {
            if let connSettings = readSettings() {
                self.doWork(settings: connSettings)
            } else {
                self.settingsMenuItemClicked(self)
            }
        }
    }
}

// MARK: - Table view data source

extension DownloadsViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        tasks.count
    }
}

// MARK: - Utilities

extension Double {
    func round(to places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - Table view delegate

extension DownloadsViewController: NSTableViewDelegate {

    @objc func startPauseButtonClicked(button: NSButton) {
        let row = downloadsTableView.row(for: button.superview!)
        guard row >= 0, row < tasks.count, let api = synologyAPI else { return }
        let task = tasks[row]
        switch task.status {
        case "paused":
            Task { try? await api.resumeTask(id: task.id) }
        case "downloading":
            Task { try? await api.pauseTask(id: task.id) }
        default:
            break
        }
    }

    @objc func deleteButtonClicked(button: NSButton) {
        let row = downloadsTableView.row(for: button.superview!)
        guard row >= 0, row < tasks.count, let api = synologyAPI else { return }
        let task = tasks[row]
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Confirm deletion"
        alert.informativeText = "Are you sure you want to delete download \"\(task.title)\"?"
        alert.addButton(withTitle: "No")
        alert.addButton(withTitle: "Yes")
        if alert.runModal() == .alertSecondButtonReturn {
            Task { try? await api.deleteTask(id: task.id) }
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = DownloadsCellView()
        let task = tasks[row]
        view.downloadNameLabel.stringValue = task.title

        let downloaded = Double(task.additional?.transfer?.sizeDownloaded ?? 0)
        let totalSize = Double(task.size)
        let progress: Double = totalSize > 0 ? (downloaded / totalSize) * 100 : 0
        let speed = Double(task.additional?.transfer?.speedDownload ?? 0)

        view.progressIndicator.doubleValue = progress
        view.progressLabel.stringValue = "\(prettifyBytesCount(bytesCount: downloaded)) of \(prettifyBytesCount(bytesCount: totalSize)) (\(Int(progress))%)"
        view.statusLabel.stringValue = "\(task.status)\n\(prettifySpeed(speed: speed))"

        switch task.status {
        case "finished":
            view.startPauseButton.image = NSImage(named: "NSStatusNoneTemplate")
        case "paused":
            view.startPauseButton.image = NSImage(named: "NSTouchBarPlayTemplate")
        case "downloading":
            view.startPauseButton.image = NSImage(named: "NSTouchBarPauseTemplate")
        default:
            break
        }

        view.startPauseButton.action = #selector(DownloadsViewController.startPauseButtonClicked)
        view.deleteButton.action = #selector(DownloadsViewController.deleteButtonClicked)

        return view
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        47
    }
}
