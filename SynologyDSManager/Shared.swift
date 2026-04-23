//
//  Shared.swift
//  SynologyDSManager
//
//  Global mutable state used across view controllers. These are
//  intentionally `nonisolated(unsafe)` — we know they're main-thread-only
//  in practice but the compiler can't prove it under strict concurrency.
//  Phase 4 (SwiftUI + Observation) replaces this file with a proper
//  `@Observable` app model.
//

import Foundation
import Cocoa


/// The DSM API client. Created in `DownloadsViewController.doWork` once
/// settings are available. View controllers read this lazily — a nil
/// value means "not signed in yet, Settings should be showing".
nonisolated(unsafe) var synologyAPI: SynologyAPI?

/// Shared TLS trust evaluator. App-wide so the first-use approval
/// callback installed by `AppDelegate` survives across reconstructions
/// of `synologyAPI` (e.g. when the user changes credentials). The
/// evaluator also owns the persisted pin store, so a single instance
/// means pins are consistent across every connection the app makes.
let synologyTrustEvaluator = SynologyTrustEvaluator()

nonisolated(unsafe) var workStarted = false
nonisolated(unsafe) var mainMethod: ((StoredCredentials) -> Void)?

nonisolated(unsafe) var mainViewController: DownloadsViewController?

nonisolated(unsafe) var currentViewController: NSViewController?


func prettifyBytesCount(bytesCount: Double) -> String {
    var factor = 1.0
    var unit = "B"
    if bytesCount > pow(1024, 4) {
        factor = pow(1024, 4)
        unit = "TB"
    } else if bytesCount > pow(1024, 3) {
        factor = pow(1024, 3)
        unit = "GB"
    } else if bytesCount > pow(1024, 2) {
        factor = pow(1024, 2)
        unit = "MB"
    } else if bytesCount > 1024 {
        factor = 1024
        unit = "KB"
    }

    return "\((bytesCount / factor).round(to: 2)) \(unit)"
}


func prettifySpeed(speed: Double) -> String {
    var factor = 1.0
    var unit = "B/s"
    if speed > pow(1024, 4) {
        factor = pow(1024, 4)
        unit = "TB/s"
    } else if speed > pow(1024, 3) {
        factor = pow(1024, 3)
        unit = "GB/s"
    } else if speed > pow(1024, 2) {
        factor = pow(1024, 2)
        unit = "MB/s"
    } else if speed > 1024 {
        factor = 1024
        unit = "KB/s"
    }

    return "\((speed / factor).round(to: 2)) \(unit)"
}
