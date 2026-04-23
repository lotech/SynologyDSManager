//
//  BTSearchViewController.swift
//  SynologyDSManager
//

import Cocoa
import Foundation


class BTSearchController: NSViewController {
    @IBOutlet weak var queryTextField: NSTextField!
    @IBOutlet weak var resultsTableview: NSTableView!
    @IBOutlet weak var noResultsLabel: NSTextField!
    @IBOutlet weak var searchSpinner: NSProgressIndicator!
    @IBOutlet weak var searchButton: NSButton!
    @IBOutlet weak var instructionsButton: NSButton!
    @IBOutlet weak var downloadButton: NSButton!
    @IBOutlet weak var searchLabel: NSTextField!
    @IBOutlet weak var destinationView: DestinationView!

    // MARK: - State

    /// The last search's results. Empty before the first search completes.
    private var results: [BTSearchResult] = []

    /// IDs of rows the user has ticked via the first-column checkbox.
    /// Kept alongside `results` (rather than embedding a mutable flag
    /// on `BTSearchResult`) because the DTO is a `Codable` struct —
    /// selection is local UI state, not part of the wire shape.
    private var selectedIDs: Set<String> = []

    /// The running search task. Stored so a second "Search" click (or
    /// view-close) can cancel an in-flight poll cleanly.
    private var searchTask: Task<Void, Never>?

    // MARK: - Actions

    @IBAction func instructionsButtonClicked(_ sender: Any) {
        NSWorkspace.shared.open(URL(string: "http://www.synoboost.com/installation/")!)
    }

    @IBAction func searchButtonClicked(_ sender: Any) {
        guard let api = synologyAPI else { return }

        // Cancel any previous in-flight search before starting a new one.
        searchTask?.cancel()
        searchTask = nil

        let query = queryTextField.stringValue

        // Enter "searching" UI state.
        results = []
        selectedIDs = []
        resultsTableview.reloadData()
        queryTextField.isEditable = false
        noResultsLabel.isHidden = true
        searchSpinner.isHidden = false
        searchLabel.isHidden = false
        searchButton.isEnabled = false
        searchSpinner.startAnimation(self)

        searchTask = Task { [weak self] in
            let outcome: Result<[BTSearchResult], Error>
            do {
                let found = try await api.searchTorrents(query: query)
                outcome = .success(found)
            } catch is CancellationError {
                return  // user started another search; don't touch UI
            } catch {
                outcome = .failure(error)
            }

            await MainActor.run {
                guard let self else { return }
                self.finishSearch(outcome)
            }
        }
    }

    @MainActor
    private func finishSearch(_ outcome: Result<[BTSearchResult], Error>) {
        searchSpinner.stopAnimation(self)
        searchSpinner.isHidden = true
        searchLabel.isHidden = true
        searchButton.isEnabled = true
        queryTextField.isEditable = true

        switch outcome {
        case .success(let newResults):
            results = newResults
            noResultsLabel.isHidden = !newResults.isEmpty
        case .failure(let error):
            AppLogger.network.error(
                "searchTorrents failed: \(error.localizedDescription, privacy: .public)"
            )
            results = []
            noResultsLabel.isHidden = false
        }

        resultsTableview.reloadData()
        selectedResultsChanged()
    }

    @IBAction func downloadButtonClicked(_ sender: Any) {
        guard let api = synologyAPI else {
            view.window?.close()
            return
        }

        let urlsToEnqueue = results
            .filter { selectedIDs.contains($0.id) }
            .map(\.dlurl)
        let destination = destinationView.selectedDir

        view.window?.close()

        Task.detached { [api] in
            for url in urlsToEnqueue {
                do {
                    try await api.createTask(url: url, destination: destination)
                } catch {
                    AppLogger.network.error(
                        "createTask(url:) from BTSearch failed: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }

    // MARK: - Selection UI state

    private func selectedResultsChanged() {
        let selected = results.filter { selectedIDs.contains($0.id) }
        let selectedCount = selected.count
        let selectedSize = selected.reduce(Int64(0)) { $0 + $1.size }

        if selectedCount > 0 {
            downloadButton.isEnabled = true
            downloadButton.state = .on
            downloadButton.highlight(true)
            downloadButton.title = "Download \(selectedCount) torrents (\(prettifyBytesCount(bytesCount: Double(selectedSize))))"
        } else {
            downloadButton.isEnabled = false
            downloadButton.title = "Select at least one search result"
        }
    }

    // MARK: - Table view setup

    private func setResultsSortDescriptors() {
        resultsTableview.tableColumns[1].sortDescriptorPrototype = NSSortDescriptor(key: "title", ascending: true)
        resultsTableview.tableColumns[2].sortDescriptorPrototype = NSSortDescriptor(key: "size", ascending: true)
        resultsTableview.tableColumns[3].sortDescriptorPrototype = NSSortDescriptor(key: "date", ascending: true)
        resultsTableview.tableColumns[4].sortDescriptorPrototype = NSSortDescriptor(key: "seeds", ascending: true)
        resultsTableview.tableColumns[5].sortDescriptorPrototype = NSSortDescriptor(key: "peers", ascending: true)
        resultsTableview.tableColumns[6].sortDescriptorPrototype = NSSortDescriptor(key: "source", ascending: true)
    }

    override func viewDidLoad() {
        resultsTableview.dataSource = self
        setResultsSortDescriptors()

        let instructionsButtonAttributedTitle = NSAttributedString(string: "here", attributes: [
            NSAttributedString.Key.foregroundColor: NSColor.linkColor,
            NSAttributedString.Key.cursor: NSCursor.pointingHand,
        ])
        instructionsButton.attributedTitle = instructionsButtonAttributedTitle

        destinationView.setSelectionSynchronizeKey(key: "main")
    }

    override func viewWillDisappear() {
        // Abandon any in-flight search when the window closes — the
        // actor's `searchTorrents` loop obeys `Task.isCancelled`.
        searchTask?.cancel()
        searchTask = nil
    }
}

// MARK: - Table view data source

extension BTSearchController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        results.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let sortDescriptor = resultsTableview.sortDescriptors.first,
              let key = sortDescriptor.key else { return }

        // Sort typed properties rather than `JSON` subscripts.
        results.sort { lhs, rhs in
            switch key {
            case "title":
                return sortDescriptor.ascending ? lhs.title < rhs.title : lhs.title > rhs.title
            case "date":
                return sortDescriptor.ascending ? lhs.date < rhs.date : lhs.date > rhs.date
            case "source":
                return sortDescriptor.ascending ? lhs.provider < rhs.provider : lhs.provider > rhs.provider
            case "size":
                return sortDescriptor.ascending ? lhs.size < rhs.size : lhs.size > rhs.size
            case "seeds":
                return sortDescriptor.ascending ? lhs.seeds < rhs.seeds : lhs.seeds > rhs.seeds
            case "peers":
                return sortDescriptor.ascending ? lhs.peers < rhs.peers : lhs.peers > rhs.peers
            default:
                return false
            }
        }
        resultsTableview.reloadData()
    }

    func tableView(_ tableView: NSTableView, setObjectValue object: Any?, for tableColumn: NSTableColumn?, row: Int) {
        // Only the first column (the checkbox) is editable.
        guard let tableColumn,
              resultsTableview.tableColumns.firstIndex(of: tableColumn) == 0,
              row >= 0, row < results.count,
              let isSelected = object as? Bool else { return }

        let id = results[row].id
        if isSelected {
            selectedIDs.insert(id)
        } else {
            selectedIDs.remove(id)
        }
        selectedResultsChanged()
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row >= 0, row < results.count else { return nil }
        let result = results[row]
        switch tableColumn?.title {
        case "Name":
            return result.title
        case "Size":
            return prettifyBytesCount(bytesCount: Double(result.size))
        case "Date":
            return result.date
        case "Seeds":
            return "\(result.seeds)"
        case "Peers":
            return "\(result.peers)"
        case "Source":
            return result.provider
        default:
            return selectedIDs.contains(result.id)
        }
    }
}
