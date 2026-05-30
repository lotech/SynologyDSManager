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
            Text("© 2020–2026 SynologyDSManager contributors")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(width: 280)
    }
}
