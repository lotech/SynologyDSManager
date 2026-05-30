//
//  Shared.swift
//  SynologyDSManager
//
//  Utility functions and global constants shared across all targets.
//  AppKit navigation anchors (mainViewController, currentViewController)
//  were removed in Phase 4 when the storyboard was replaced with
//  pure SwiftUI Window scenes.
//

import Foundation
import Cocoa


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
