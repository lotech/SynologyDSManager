//
//  ChooseDestView.swift
//  SynologyDSManager
//

import SwiftUI


// MARK: - RemoteDir

@Observable
final class RemoteDir: Identifiable {
    let id = UUID()
    let name: String
    let absolutePath: String
    var children: [RemoteDir] = []
    var isLoading: Bool = false
    var didFetchChildren: Bool = false

    init(name: String, absolutePath: String) {
        self.name = name
        self.absolutePath = absolutePath
    }
}


// MARK: - State

@Observable
@MainActor
final class ChooseDestState {
    var remoteDirs: [RemoteDir] = []
    var selectedDir: RemoteDir?
    var onDismiss: ((String?) -> Void)?

    func loadRootDirectories() {
        guard let api = AppModel.shared.api else { return }
        Task {
            do {
                let entries = try await api.listDirectories(root: "/")
                self.remoteDirs = entries.map { RemoteDir(name: $0.name, absolutePath: $0.path) }
            } catch {
                AppLogger.network.error(
                    "listDirectories(root: /) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}


// MARK: - Recursive row

private struct RemoteDirRow: View {
    @Bindable var dir: RemoteDir
    @Binding var selectedDir: RemoteDir?
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if dir.isLoading {
                Label("Loading…", systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(dir.children) { child in
                    RemoteDirRow(dir: child, selectedDir: $selectedDir)
                }
            }
        } label: {
            Label(dir.name, systemImage: "folder")
                .foregroundStyle(selectedDir?.id == dir.id ? Color.accentColor : .primary)
                .contentShape(Rectangle())
                .onTapGesture { selectedDir = dir }
        }
        .onChange(of: isExpanded) { _, expanded in
            if expanded && !dir.didFetchChildren {
                Task { await loadChildren() }
            }
        }
    }

    @MainActor
    private func loadChildren() async {
        guard let api = AppModel.shared.api else { return }
        dir.isLoading = true
        do {
            let entries = try await api.listDirectories(root: dir.absolutePath)
            dir.children = entries.map { RemoteDir(name: $0.name, absolutePath: $0.path) }
            dir.didFetchChildren = true
            dir.isLoading = false
        } catch {
            dir.didFetchChildren = true
            dir.isLoading = false
            AppLogger.network.error(
                "listDirectories(root: \(dir.absolutePath, privacy: .private)) failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}


// MARK: - View

struct ChooseDestView: View {
    let state: ChooseDestState

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(state.remoteDirs) { dir in
                    RemoteDirRow(dir: dir, selectedDir: Binding(
                        get: { state.selectedDir },
                        set: { state.selectedDir = $0 }
                    ))
                }
            }
            .listStyle(.sidebar)

            Divider()

            HStack {
                Button("Cancel") { state.onDismiss?(nil) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("OK") { state.onDismiss?(state.selectedDir?.absolutePath) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(state.selectedDir == nil)
            }
            .padding(12)
        }
        .frame(width: 260, height: 360)
        .onAppear { state.loadRootDirectories() }
    }
}


// MARK: - Hosting controller (used by DestinationPicker for "Other…" sheet)

final class ChooseDestHostingController: NSHostingController<ChooseDestView> {
    var completion: ((String?) -> Void)?
    private let destState: ChooseDestState

    // Plain init for programmatic use (no storyboard needed).
    init() {
        let s = ChooseDestState()
        destState = s
        super.init(rootView: ChooseDestView(state: s))
        sizingOptions = .preferredContentSize
        s.onDismiss = { [weak self] path in
            guard let self else { return }
            let comp = self.completion
            self.dismiss(self)
            if let path { comp?(path) }
        }
    }

    required init?(coder: NSCoder) {
        let s = ChooseDestState()
        destState = s
        super.init(coder: coder, rootView: ChooseDestView(state: s))
        sizingOptions = .preferredContentSize
        s.onDismiss = { [weak self] path in
            guard let self else { return }
            let comp = self.completion
            self.dismiss(self)
            if let path { comp?(path) }
        }
    }
}
