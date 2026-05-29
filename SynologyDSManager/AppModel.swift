//
//  AppModel.swift
//  SynologyDSManager
//
//  Phase 4 replacement for the nonisolated(unsafe) globals in Shared.swift.
//  Owns the live SynologyAPI client, the shared TLS evaluator, and the
//  connection lifecycle state that was previously scattered across
//  Shared.swift and accessed from every view controller.
//
//  Concurrency contract: @MainActor throughout. All reads and writes from
//  view controllers are already on the main actor, so this matches the
//  existing implicit behaviour and makes it explicit.
//

import Foundation
import Observation


@Observable
@MainActor
final class AppModel {

    // MARK: - Singleton

    static let shared = AppModel()
    private init() {}

    // MARK: - App-wide singletons

    /// The active DSM API client. Nil until the user completes their
    /// first Settings → "Connect and save" flow. View controllers guard
    /// on this value before issuing any API calls.
    private(set) var api: SynologyAPI?

    /// Shared TLS trust evaluator. Long-lived so the SPKI pin store and
    /// the first-use approval callback installed by AppDelegate survive
    /// across reconstructions of `api` (e.g. credential changes).
    let trustEvaluator = SynologyTrustEvaluator()

    // MARK: - Connection lifecycle

    /// Set to true after `doWork` runs for the first time. SettingsView
    /// uses this to decide whether a successful test-connection should
    /// start the refresh loop or just update existing credentials.
    private(set) var workStarted = false

    /// Set by DownloadsViewController.viewDidLoad; called by SettingsView
    /// when the user saves credentials for the first time (i.e. !workStarted).
    var connect: ((StoredCredentials) -> Void)?

    // MARK: - Mutators called by DownloadsViewController

    func setAPI(_ newAPI: SynologyAPI) {
        api = newAPI
    }

    func markWorkStarted() {
        workStarted = true
    }

    // MARK: - Credential persistence (delegating to Settings.swift helpers)

    func loadCredentials() -> StoredCredentials? {
        readSettings()
    }

    func saveCredentials(_ credentials: StoredCredentials) {
        storeSettings(credentials)
    }
}
