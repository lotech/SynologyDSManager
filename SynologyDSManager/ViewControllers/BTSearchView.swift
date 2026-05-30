//
//  BTSearchView.swift
//  SynologyDSManager
//
//  SwiftUI replacement for BTSearchController (Phase 4, slice 3).
//  Dead link to synoboost.com removed per MODERNIZATION_PLAN Phase 4 task.
//

import SwiftUI


// MARK: - State

@Observable
@MainActor
final class BTSearchState {
    var query: String = ""
    var results: [BTSearchResult] = []
    var selectedIDs: Set<String> = []
    var isSearching: Bool = false
    var showNoResults: Bool = false

    private var searchTask: Task<Void, Never>?

    func startSearch(api: SynologyAPI) {
        searchTask?.cancel()
        results = []
        selectedIDs = []
        isSearching = true
        showNoResults = false

        searchTask = Task { [weak self] in
            guard let self else { return }
            let outcome: Result<[BTSearchResult], Error>
            do {
                let found = try await api.searchTorrents(query: self.query)
                outcome = .success(found)
            } catch is CancellationError {
                return
            } catch {
                outcome = .failure(error)
            }
            self.isSearching = false
            switch outcome {
            case .success(let found):
                self.results = found
                self.showNoResults = found.isEmpty
            case .failure(let error):
                AppLogger.network.error(
                    "searchTorrents failed: \(error.localizedDescription, privacy: .public)"
                )
                self.results = []
                self.showNoResults = true
            }
        }
    }

    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }
}


// MARK: - View

struct BTSearchView: View {
    @Bindable var state: BTSearchState
    var onClose: () -> Void = {}

    @State private var sortOrder: [KeyPathComparator<BTSearchResult>] = []

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            resultsTable
            Divider()
            bottomBar
        }
        .frame(minWidth: 640, minHeight: 400)
        .onDisappear { state.cancelSearch() }
    }

    // MARK: Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            TextField("Search query", text: $state.query)
                .textFieldStyle(.roundedBorder)
                .disabled(state.isSearching)
                .onSubmit { triggerSearch() }

            Button("Search", action: triggerSearch)
                .disabled(state.isSearching || state.query.isEmpty)

            if state.isSearching {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
    }

    // MARK: Results table

    private var resultsTable: some View {
        Group {
            if state.results.isEmpty && !state.isSearching {
                VStack {
                    Spacer()
                    if state.showNoResults {
                        Text("No results found")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Enter a search query above")
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            } else {
                Table(state.results, selection: $state.selectedIDs, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.title)
                        .width(min: 200, ideal: 280)
                    TableColumn("Size", value: \.size) { row in
                        Text(prettifyBytesCount(bytesCount: Double(row.size)))
                            .monospacedDigit()
                    }
                    .width(80)
                    TableColumn("Date", value: \.date)
                        .width(90)
                    TableColumn("Seeds", value: \.seeds) { row in
                        Text("\(row.seeds)").monospacedDigit()
                    }
                    .width(55)
                    TableColumn("Peers", value: \.peers) { row in
                        Text("\(row.peers)").monospacedDigit()
                    }
                    .width(55)
                    TableColumn("Source", value: \.provider)
                        .width(90)
                }
                .onChange(of: sortOrder) { _, newOrder in
                    state.results.sort(using: newOrder)
                }
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack {
            DestinationViewRepresentable(synchronizeKey: "main")
                .frame(height: 24)

            Spacer()

            Button(downloadButtonTitle, action: startDownload)
                .disabled(state.selectedIDs.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .padding(10)
    }

    // MARK: Helpers

    private var downloadButtonTitle: String {
        if state.selectedIDs.isEmpty {
            return "Select at least one search result"
        }
        let selected = state.results.filter { state.selectedIDs.contains($0.id) }
        let totalSize = selected.reduce(Int64(0)) { $0 + $1.size }
        return "Download \(selected.count) torrents (\(prettifyBytesCount(bytesCount: Double(totalSize))))"
    }

    private func triggerSearch() {
        guard let api = AppModel.shared.api else { return }
        state.startSearch(api: api)
    }

    private func startDownload() {
        guard let api = AppModel.shared.api else { onClose(); return }
        let urlsToEnqueue = state.results
            .filter { state.selectedIDs.contains($0.id) }
            .map(\.dlurl)
        let destination = userDefaults.string(forKey: "destinationSelectedPath_main")
        onClose()
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
}


// MARK: - Hosting controller

final class BTSearchHostingController: NSHostingController<BTSearchView> {
    private let searchState: BTSearchState

    required init?(coder: NSCoder) {
        let s = BTSearchState()
        self.searchState = s
        super.init(coder: coder, rootView: BTSearchView(state: s))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rootView.onClose = { [weak self] in self?.view.window?.close() }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.styleMask.remove(.fullScreen)
        view.window?.styleMask.remove(.miniaturizable)
    }
}
