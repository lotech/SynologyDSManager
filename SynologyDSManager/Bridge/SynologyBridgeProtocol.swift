//
//  SynologyBridgeProtocol.swift
//  SynologyDSManager
//
//  XPC protocol used by the Safari Web Extension's native messaging host
//  (added in Phase 3b) to enqueue downloads with the main app. Replaces
//  the Phase-0-audit-flagged loopback HTTP bridge (`Webserver.swift` +
//  Swifter), which accepted any local POST without authentication.
//
//  Why `@objc`? `NSXPCConnection` marshals calls through the Obj-C
//  runtime — protocols used with it must be `@objc` and their
//  parameters must be Objective-C representable. That's why the reply
//  is a completion block rather than an `async`-returning function and
//  why the URL is passed as a `String` rather than a `URL`.
//
//  Phase 3b additions
//  ------------------
//  When the native messaging host lands it will use this same protocol
//  via `NSXPCInterface(with: SynologyBridgeProtocol.self)`. Any endpoint
//  added here must also be mirrored on the host's side.
//

import Foundation


/// Minimal XPC surface the Safari extension reaches into the main app
/// through. Intentionally tiny: everything the extension needs to do
/// funnels through `enqueueDownload`, which is the only thing a third-
/// party-code peer should be able to trigger. More surface area = more
/// things to review for security.
@objc protocol SynologyBridgeProtocol {

    /// Ask the main app to enqueue a DSM download for `url`.
    ///
    /// - Parameters:
    ///   - url: HTTP/HTTPS/FTP URL or a magnet/ed2k link. Validation
    ///     happens app-side; the extension is untrusted input.
    ///   - reply: `(accepted, errorMessage)`. `accepted == true` means
    ///     the download request was handed to `SynologyAPI` — not that
    ///     DSM has acknowledged it yet. `errorMessage` is non-nil only
    ///     when `accepted == false` and is safe to show to the user
    ///     (no internal state / session IDs). `@Sendable` because
    ///     `NSXPCConnection` may invoke it on its private queue and
    ///     the service implementation hops to its own `Task` before
    ///     calling it — so the closure crosses isolation boundaries.
    func enqueueDownload(url: String, reply: @Sendable @escaping (Bool, String?) -> Void)
}
