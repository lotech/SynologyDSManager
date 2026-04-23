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
            respond(to: context, ok: false, error: "Malformed message from extension.")
            return
        }

        switch message["action"] as? String {
        case "enqueueDownload":
            guard let url = message["url"] as? String else {
                respond(to: context, ok: false, error: "Missing 'url' field.")
                return
            }
            enqueueDownload(url: url, context: context)

        default:
            respond(to: context, ok: false, error: "Unknown action.")
        }
    }

    /// Open a one-shot XPC connection to the main app, call
    /// `enqueueDownload(url:reply:)`, and forward the reply back to JS.
    /// The connection is invalidated after a single call — we don't
    /// keep it alive across Safari's message dispatches.
    private func enqueueDownload(url: String, context: NSExtensionContext) {
        let connection = NSXPCConnection(machServiceName: Self.bridgeMachServiceName,
                                         options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: SynologyBridgeProtocol.self)

        connection.invalidationHandler = { [weak self] in
            log.notice("bridge connection invalidated before reply")
            self?.respond(to: context, ok: false,
                          error: "Lost connection to Synology DS Manager. Is the app running?")
        }
        connection.interruptionHandler = { [weak self] in
            log.notice("bridge connection interrupted before reply")
            self?.respond(to: context, ok: false,
                          error: "Synology DS Manager stopped responding.")
        }

        connection.resume()

        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            log.error("remoteObjectProxy error \(error.localizedDescription, privacy: .public)")
            self?.respond(to: context, ok: false,
                          error: "Couldn't reach Synology DS Manager: \(error.localizedDescription)")
            connection.invalidate()
        } as? SynologyBridgeProtocol

        guard let proxy else {
            respond(to: context, ok: false,
                    error: "Couldn't acquire bridge proxy.")
            connection.invalidate()
            return
        }

        proxy.enqueueDownload(url: url) { [weak self] accepted, message in
            self?.respond(to: context, ok: accepted, error: accepted ? nil : message)
            connection.invalidate()
        }
    }

    /// Build and complete the Safari extension reply.
    private func respond(to context: NSExtensionContext, ok: Bool, error: String?) {
        var payload: [String: Any] = ["ok": ok]
        if let error { payload["error"] = error }

        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [reply], completionHandler: nil)
    }
}
