//
//  SafariWebExtensionHandler.swift
//  SynologyDSManager Web Extension
//
//  Bridges the Web Extension's JavaScript environment to the main app
//  over XPC. Safari spawns this class (inside the extension's sandbox)
//  whenever the extension's service worker or content script calls
//  `browser.runtime.sendNativeMessage(...)`.
//
//  Wire format of `message` (JS → Swift):
//
//      { "action": "enqueueDownload", "url": "https://…/ubuntu.iso" }
//
//  Reply shape (Swift → JS):
//
//      { "ok": true }
//      { "ok": false, "error": "human-readable message" }
//
//  The handler never talks to the Synology NAS directly — it's just
//  a thin forwarder onto the main app's authorisation-gated XPC
//  listener (see `SynologyBridgeListener` / `ClientAuthorization`
//  in the main target). Keeping the network code in exactly one
//  place limits the credential surface to the main app.
//

import Foundation
import SafariServices
import os

private let log = Logger(subsystem: "com.skavans.synologyDSManager.webextension",
                         category: "handler")


final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {

    /// Mach service name the main app's `SynologyBridgeListener` will
    /// register with launchd in Phase 3b-2 (via a bundled LaunchAgent
    /// plist). Must stay in sync with the `MachServices` key of
    /// `SynologyDSManager/LaunchAgents/com.skavans.synologyDSManager.bridge.plist`.
    private static let bridgeMachServiceName = "com.skavans.synologyDSManager.bridge"

    func beginRequest(with context: NSExtensionContext) {
        guard
            let item = context.inputItems.first as? NSExtensionItem,
            let userInfo = item.userInfo as? [String: Any],
            let message = userInfo[SFExtensionMessageKey] as? [String: Any]
        else {
            Self.respond(to: context, ok: false, error: "Malformed message from extension.")
            return
        }

        switch message["action"] as? String {
        case "enqueueDownload":
            guard let url = message["url"] as? String else {
                Self.respond(to: context, ok: false, error: "Missing 'url' field.")
                return
            }
            Self.enqueueDownload(url: url, context: context)

        default:
            Self.respond(to: context, ok: false, error: "Unknown action.")
        }
    }

    /// Open a one-shot XPC connection to the main app, call
    /// `enqueueDownload(url:reply:)`, and forward the reply back to JS.
    /// The connection is invalidated after a single call — we don't
    /// keep it alive across Safari's message dispatches.
    ///
    /// A `CheckedContinuation` bridges XPC's `@Sendable` reply closure
    /// into this `Task`'s context so `NSExtensionContext` and
    /// `NSXPCConnection` (both non-`Sendable`) never cross an isolation
    /// boundary — only `(Bool, String?)` does, and both are `Sendable`.
    private static func enqueueDownload(url: String, context: NSExtensionContext) {
        let connection = NSXPCConnection(machServiceName: bridgeMachServiceName,
                                         options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: SynologyBridgeProtocol.self)

        connection.invalidationHandler = {
            log.notice("bridge connection invalidated")
        }
        connection.interruptionHandler = {
            log.notice("bridge connection interrupted")
        }
        connection.resume()

        // Wrap the non-`Sendable` values we need past the upcoming
        // `Task` boundary. The wrapped values outlive exactly one XPC
        // round-trip and aren't touched concurrently from anywhere else,
        // so the `@unchecked` is safe in practice.
        let contextBox = UncheckedBox(context)
        let connectionBox = UncheckedBox(connection)

        Task {
            let (ok, errorMessage) = await fetchReply(from: connectionBox.value, url: url)
            respond(to: contextBox.value, ok: ok, error: ok ? nil : errorMessage)
            connectionBox.value.invalidate()
        }
    }

    /// Open a proxy on `connection`, ask it to enqueue `url`, and return
    /// the reply. Uses a `CheckedContinuation` so the `@Sendable` reply
    /// closure only ever captures `continuation` (which is `Sendable`).
    private static func fetchReply(from connection: NSXPCConnection,
                                   url: String) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                log.error("remoteObjectProxy error \(error.localizedDescription, privacy: .public)")
                continuation.resume(returning: (
                    false,
                    "Couldn't reach Synology DS Manager: \(error.localizedDescription)"
                ))
            } as? SynologyBridgeProtocol

            guard let proxy else {
                continuation.resume(returning: (false, "Couldn't acquire bridge proxy."))
                return
            }

            proxy.enqueueDownload(url: url) { accepted, message in
                continuation.resume(returning: (accepted, message))
            }
        }
    }

    /// Build and complete the Safari extension reply.
    private static func respond(to context: NSExtensionContext, ok: Bool, error: String?) {
        var payload: [String: Any] = ["ok": ok]
        if let error { payload["error"] = error }

        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }
}


/// `@unchecked Sendable` envelope for values that aren't formally
/// `Sendable` but are only ever touched on one thread at a time for the
/// duration of a single XPC round-trip (`NSXPCConnection`,
/// `NSExtensionContext`). Kept `private` so nothing else in the module
/// can reach for it.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
