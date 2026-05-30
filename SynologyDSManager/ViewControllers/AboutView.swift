//
//  AboutView.swift
//  SynologyDSManager
//

import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            Text("Synology DS Manager")
                .font(.headline)
            Text("version \(version)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Icons by icons8") {
                NSWorkspace.shared.open(URL(string: "https://icons8.com")!)
            }
            .buttonStyle(.link)
            Text("© 2021 Anton Subbotin (skavans)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 280)
    }
}

final class AboutHostingController: NSHostingController<AboutView> {
    required init?(coder: NSCoder) {
        super.init(coder: coder, rootView: AboutView())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        sizingOptions = .preferredContentSize
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        view.window?.styleMask.remove(.fullScreen)
        view.window?.styleMask.remove(.miniaturizable)
        view.window?.styleMask.remove(.resizable)
    }
}
