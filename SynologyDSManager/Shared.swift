//
//  Shared.swift
//  SynologyDSManager
//
//  AppKit navigation anchors used across view controllers while the
//  storyboard-based screens are still AppKit. These go away as each
//  remaining screen is ported to SwiftUI in Phase 4.
//
//  The four former globals (synologyAPI, synologyTrustEvaluator,
//  workStarted, mainMethod) now live in AppModel.
//

import Foundation
import Cocoa


/// The main downloads window controller. Set by
/// DownloadsHostingController.viewDidLoad. Used by DestinationView to find
/// a storyboard to instantiate dirSelectorVC from, and by SettingsView
/// to refocus the main window after Settings closes.
nonisolated(unsafe) var mainViewController: DownloadsHostingController?

/// The view controller currently displayed in a secondary window (e.g.
/// Settings, AddDownload, BTSearch). Set by showStoryboardWindowCenteredToMainWindow.
/// Used by DestinationView to call presentAsSheet on the right host.
nonisolated(unsafe) var currentViewController: NSViewController?


extension Double {
    func round(to places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}


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
