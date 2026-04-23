//
//  AddDownloadViewController.swift
//  SynologyDSManager
//
//  Created by Антон on 15.03.2020.
//  Copyright © 2020 skavans. All rights reserved.
//

import Cocoa
import Foundation
import UniformTypeIdentifiers


class AddDownloadViewController: NSViewController {
    @IBOutlet weak var startDownloadButton: NSButton!
    @IBOutlet var tasksTextView: NSTextView!
    @IBOutlet weak var tasksScrollView: NSScrollView!
    @IBOutlet weak var destinationView: DestinationView!
    
    var torrents: [String] = []
    var urls: [String] = []
    
    @IBAction func startDownloadButtonClicked(_ sender: Any) {
        guard let api = synologyAPI else {
            // Without a client there's nothing to submit to. This
            // shouldn't be reachable from the UI flow — the Add window
            // is only shown after Settings → Test Connection succeeds —
            // but guarding keeps a malformed state from crashing.
            self.view.window?.close()
            return
        }

        // Snapshot the current input lists before closing the window so
        // the detached task still has what it needs.
        let torrentPaths = torrents
        let urlStrings = urls
        let destination = self.destinationView.selectedDir

        // Close immediately — the sheet doesn't need to stay open while
        // the enqueues happen. Errors get logged; DSM's list refresh in
        // DownloadsViewController will show what actually landed.
        self.view.window?.close()

        Task.detached { [api] in
            for path in torrentPaths {
                do {
                    try await api.createTask(
                        torrentFile: URL(fileURLWithPath: path),
                        destination: destination
                    )
                } catch {
                    AppLogger.network.error(
                        "createTask(torrentFile:) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            for url in urlStrings {
                do {
                    try await api.createTask(url: url, destination: destination)
                } catch {
                    AppLogger.network.error(
                        "createTask(url:) failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }
    
    @IBAction func chooseTorrentFileButtonClicked(_ sender: Any) {
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

        guard dialog.runModal() == NSApplication.ModalResponse.OK else { return }

        self.tasksTextView.string = dialog.urls.reduce("") { acc, url in
            acc + "\(url.path)\n"
        } + self.tasksTextView.string

        self.tasksTextView.delegate?.textDidChange?(Notification(name: .init("textChanged")))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tasksTextView.delegate = self
        self.destinationView.setSelectionSynchronizeKey(key: "main")
    }
    
    override func viewWillAppear() {
        self.view.window?.styleMask.remove(.fullScreen)
        self.view.window?.styleMask.remove(.miniaturizable)
        self.view.window?.styleMask.remove(.resizable)
        
        self.tasksScrollView.hasHorizontalScroller = true
        tasksTextView.maxSize = NSMakeSize(CGFloat(Float.greatestFiniteMagnitude), CGFloat(Float.greatestFiniteMagnitude))
        tasksTextView.isHorizontallyResizable = true
        tasksTextView.textContainer?.widthTracksTextView = false
        tasksTextView.textContainer?.containerSize = NSMakeSize(CGFloat(Float.greatestFiniteMagnitude), CGFloat(Float.greatestFiniteMagnitude))
    }
}

extension AddDownloadViewController: NSTextViewDelegate {
    
    func textDidChange(_ notification: Notification) {
        torrents = []
        urls = []
                
        func isURL(str: String) -> Bool {
            return (str.hasPrefix("http") || str.hasPrefix("ftp") || str.hasPrefix("ed2k") || str.hasPrefix("magnet"))
        }
        
        for line in self.tasksTextView.string.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed != "" {
                if trimmed.hasPrefix("/") && trimmed.hasSuffix(".torrent") {
                    torrents.append(trimmed)
                } else if isURL(str: trimmed) {
                    urls.append(trimmed)
                }
            }
        }
        
        if torrents.count > 0 || urls.count > 0 {
            startDownloadButton.isEnabled = true
            startDownloadButton.title = "Download \(torrents.count) torrents and \(urls.count) URLs"
            startDownloadButton.highlight(true)
        } else {
            startDownloadButton.isEnabled = false
            startDownloadButton.title = "Add at least one URL or torrent-file"
        }
    }
    
}
