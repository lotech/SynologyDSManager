//
//  ChooseDestViewController.swift
//  SynologyDSManager
//

import Cocoa
import Foundation


/// Mutable tree node used to back the `NSOutlineView`. A reference type
/// is necessary: the outline view identifies rows by their `item` object
/// and expects the same object back for expand/collapse callbacks.
/// Lazy-loaded children get appended in place as the user expands rows.
///
/// Previously declared in `SynologyClient.swift`; kept local to the
/// destination-picker view controller since nothing else uses it.
final class RemoteDir {
    let name: String
    var children: [RemoteDir]
    let absolutePath: String
    /// `true` once we've fetched the children (even if the fetch
    /// returned zero). Avoids re-hitting the NAS every time the user
    /// collapses and re-expands an empty directory.
    var didFetchChildren: Bool

    init(name: String, absolutePath: String, children: [RemoteDir] = [], didFetchChildren: Bool = false) {
        self.name = name
        self.absolutePath = absolutePath
        self.children = children
        self.didFetchChildren = didFetchChildren
    }
}


class ChooseDestViewController: NSViewController {

    @IBOutlet weak var okButton: NSButton!
    @IBOutlet weak var dirsOutlineView: NSOutlineView!

    private var remoteDirs: [RemoteDir] = []

    public var completion: ((_ selectedPath: String?) -> Void)?

    @IBAction func cancelButtonClicked(_ sender: Any) {
        dismiss(self)
    }

    @IBAction func okButtonClicked(_ sender: Any) {
        let selectedRow = dirsOutlineView.selectedRow
        let selectedItem = dirsOutlineView.item(atRow: selectedRow)
        guard let remoteDir = selectedItem as? RemoteDir else {
            dismiss(self)
            return
        }
        let path = remoteDir.absolutePath
        dismiss(self)
        completion?(path)
    }

    override func viewDidLoad() {
        dirsOutlineView.dataSource = self
        dirsOutlineView.delegate = self

        guard let api = synologyAPI else { return }
        Task { [weak self] in
            do {
                let entries = try await api.listDirectories(root: "/")
                await MainActor.run {
                    self?.remoteDirs = entries.map {
                        RemoteDir(name: $0.name, absolutePath: $0.path)
                    }
                    self?.dirsOutlineView.reloadData()
                }
            } catch {
                AppLogger.network.error(
                    "listDirectories(root:/) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Fetch the children of `dir` from the NAS and splice them in.
    /// Main-actor-isolated so the outline-view mutations are safe.
    @MainActor
    private func loadChildren(of dir: RemoteDir) async {
        guard let api = synologyAPI else { return }
        do {
            let entries = try await api.listDirectories(root: dir.absolutePath)
            dir.children = entries.map {
                RemoteDir(name: $0.name, absolutePath: $0.path)
            }
            dir.didFetchChildren = true
            dirsOutlineView.reloadItem(dir, reloadChildren: true)
            dirsOutlineView.expandItem(dir)
        } catch {
            dir.didFetchChildren = true  // don't keep retrying on failure
            AppLogger.network.error(
                "listDirectories(root: \(dir.absolutePath, privacy: .private)) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}


extension ChooseDestViewController: NSOutlineViewDataSource {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let item else { return remoteDirs.count }
        guard let dir = item as? RemoteDir else { return 0 }
        return dir.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item else { return remoteDirs[index] }
        return (item as! RemoteDir).children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        // Directories in DSM may have subdirectories. Optimistically say
        // yes so the disclosure triangle appears; if a directory turns
        // out to be empty after fetch, the triangle collapses away.
        true
    }

    func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
        guard let dir = item as? RemoteDir else { return true }

        // Already-fetched: allow the expansion immediately.
        if dir.didFetchChildren {
            return true
        }

        // First time: kick off a fetch and defer expansion until the
        // children land. Return false to block this expand attempt;
        // `loadChildren(of:)` re-triggers expand after the reload.
        Task { @MainActor [weak self] in
            await self?.loadChildren(of: dir)
        }
        return false
    }
}


extension ChooseDestViewController: NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let remoteDir = item as? RemoteDir else { return nil }
        let view = dirsOutlineView.makeView(withIdentifier: .init("DataCell"), owner: self) as? NSTableCellView
        view?.textField?.stringValue = remoteDir.name
        return view
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        okButton.isEnabled = true
    }
}
