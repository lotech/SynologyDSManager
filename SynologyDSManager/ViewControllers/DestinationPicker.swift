//
//  DestinationPicker.swift
//  SynologyDSManager
//

import SwiftUI
import AppKit


// MARK: - Persistence

/// A user-chosen download directory shown in the picker. Synthetic menu
/// entries (the "Download Station default" row, the legacy separator, the
/// "Other…" action) are *not* represented here — only real remote
/// directories the user has browsed to.
private struct DestinationEntry: Identifiable, Hashable {
    let title: String
    let path: String
    var id: String { path }
}

/// UserDefaults-backed store for the destination list and per-screen
/// selection. The on-disk shapes are unchanged from the AppKit
/// `DestinationView` era so existing installs round-trip cleanly:
///
/// - `downloadDestinations` — a JSON `[[title, path_or_null], …]` array.
///   The first three rows are the synthetic placeholders the old popup
///   rebuilt at launch; the remainder are real directories.
/// - `destinationSelectedTitle_<key>` / `destinationSelectedPath_<key>` —
///   the selection for a given synchronize key (`"main"`, `"extension"`).
///   An absent path means "Download Station default", which is exactly
///   what the download call sites read back.
private enum DestinationStore {
    static let listKey = "downloadDestinations"
    static let defaultTitle = "Download Station default"

    static func loadCustomDirs() -> [DestinationEntry] {
        guard let json = userDefaults.string(forKey: listKey),
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([[String?]].self, from: data)
        else { return [] }
        // Keep only entries with a real path — this drops the synthetic
        // "Download Station default" / "SEPARATOR" / "Other..." rows, all
        // of which were stored with a null path.
        return arr.compactMap { pair in
            guard pair.count >= 2, let title = pair[0], let path = pair[1] else { return nil }
            return DestinationEntry(title: title, path: path)
        }
    }

    static func saveCustomDirs(_ dirs: [DestinationEntry]) {
        // Re-emit the original on-disk shape: synthetic placeholders first,
        // then the user's directories.
        var arr: [[String?]] = [[defaultTitle, nil], ["SEPARATOR", nil], ["Other...", nil]]
        arr.append(contentsOf: dirs.map { [$0.title, $0.path] })
        guard let data = try? JSONEncoder().encode(arr),
              let json = String(data: data, encoding: .utf8) else { return }
        userDefaults.set(json, forKey: listKey)
    }

    static func selectedPath(for key: String) -> String? {
        userDefaults.string(forKey: "destinationSelectedPath_\(key)")
    }

    static func saveSelection(title: String, path: String?, key: String) {
        userDefaults.set(title, forKey: "destinationSelectedTitle_\(key)")
        if let path {
            userDefaults.set(path, forKey: "destinationSelectedPath_\(key)")
        } else {
            userDefaults.removeObject(forKey: "destinationSelectedPath_\(key)")
        }
    }
}


// MARK: - Picker

/// SwiftUI replacement for the xib-backed `DestinationView`. A pop-up
/// menu of download destinations whose selection persists to the same
/// UserDefaults keys the download call sites read. Picking "Other…"
/// presents the existing `ChooseDestHostingController` sheet to browse
/// the NAS file tree and add a new directory.
struct DestinationPicker: View {
    let synchronizeKey: String

    @State private var customDirs: [DestinationEntry] = []
    @State private var selectedPath: String?      // nil == Download Station default
    @State private var selectionTag = ""          // "" == default; otherwise a path or the "Other…" sentinel

    // A tag the user would never type as a real path, used to model the
    // "Other…" *action* inside a value-based Picker.
    private static let otherTag = "\u{1}choose-other"

    var body: some View {
        Picker("", selection: $selectionTag) {
            Text(DestinationStore.defaultTitle).tag("")
            if !customDirs.isEmpty {
                Divider()
                ForEach(customDirs) { entry in
                    Text(entry.title).tag(entry.path)
                }
            }
            Divider()
            Text("Other…").tag(Self.otherTag)
        }
        .labelsHidden()
        .onChange(of: selectionTag) { _, tag in handle(tag) }
        .onAppear(perform: load)
    }

    // MARK: Actions

    private func load() {
        customDirs = DestinationStore.loadCustomDirs()
        let saved = DestinationStore.selectedPath(for: synchronizeKey)
        selectedPath = saved
        selectionTag = saved ?? ""
    }

    private func handle(_ tag: String) {
        if tag == Self.otherTag {
            // "Other…" is an action, not a value — revert the visible
            // selection to where it was, then open the directory browser.
            selectionTag = selectedPath ?? ""
            presentChooser()
            return
        }
        let path: String? = tag.isEmpty ? nil : tag
        selectedPath = path
        let title = customDirs.first { $0.path == path }?.title ?? DestinationStore.defaultTitle
        DestinationStore.saveSelection(title: title, path: path, key: synchronizeKey)
    }

    private func presentChooser() {
        let chooser = ChooseDestHostingController()
        chooser.completion = { selectedPath in
            if let selectedPath { addAndSelect(selectedPath) }
        }
        NSApp.keyWindow?.contentViewController?.presentAsSheet(chooser)
    }

    private func addAndSelect(_ path: String) {
        var dirs = customDirs.filter { $0.path != path }
        let dirName = path.split(separator: "/").last.map(String.init) ?? path
        let title = "\(dirName) (\(path))"
        dirs.insert(DestinationEntry(title: title, path: path), at: 0)
        customDirs = dirs
        DestinationStore.saveCustomDirs(dirs)

        selectedPath = path
        selectionTag = path
        DestinationStore.saveSelection(title: title, path: path, key: synchronizeKey)
    }
}
