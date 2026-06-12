//
//  AboutView.swift
//  SynologyDSManager
//

import SwiftUI

struct AboutView: View {
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    private let repoURL = URL(string: "https://github.com/lotech/SynologyDSManager")

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

            if let repoURL {
                Link("View on GitHub", destination: repoURL)
                    .font(.subheadline)
            }

            Text("Originally created by [@skavans](https://github.com/skavans), and updated to Swift by [@lotech](https://github.com/lotech).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("© 2020–2026 SynologyDSManager contributors")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 300)
    }
}
