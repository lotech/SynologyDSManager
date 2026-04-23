//
//  SafariExtensionHandler.swift
//  SynologyDSManager Extension
//

import Foundation
import SafariServices
import AppKit


class SafariExtensionHandler: SFSafariExtensionHandler {

    /// Loopback endpoint the main app's (unauthenticated) local webserver
    /// listens on. This whole bridge — Alamofire → URLSession, and the
    /// HTTP server itself — is being replaced in Phase 3 by an
    /// `NSXPCConnection`-based native-messaging host to a new
    /// Safari Web Extension. Until then, keep the shape identical to
    /// the original behaviour: POST JSON, fall back to the URL scheme.
    private static let loopbackURL = URL(string: "http://localhost:11863/add_download")!

    override func messageReceived(withName messageName: String, from page: SFSafariPage, userInfo: [String: Any]?) {
        // Capture a string description up front. `[String: Any]?` isn't
        // `Sendable` and `getPropertiesWithCompletionHandler`'s closure
        // is `@Sendable` under strict concurrency — capturing the raw
        // dictionary into the closure would warn. The string version
        // is a plain `String` so it crosses the boundary cleanly.
        let userInfoDescription = "\(userInfo ?? [:])"
        page.getPropertiesWithCompletionHandler { properties in
            NSLog("The extension received a message (\(messageName)) from a script injected into (\(String(describing: properties?.url))) with userInfo (\(userInfoDescription))")
        }

        guard messageName == "downloadURL",
              let urlString = userInfo?["URL"] as? String,
              !urlString.isEmpty else { return }

        Self.postToLoopback(urlString: urlString) { delivered in
            guard !delivered else { return }
            Self.openAppViaURLScheme(urlString: urlString)
        }
    }

    override func contextMenuItemSelected(withCommand command: String, in page: SFSafariPage, userInfo: [String: Any]? = nil) {
        switch command {
        case "downloadURL":
            page.dispatchMessageToScript(withName: "downloadURL", userInfo: nil)
        default:
            break
        }
    }

    // MARK: - Transport

    /// POST `{"url": urlString}` to the main app's loopback bridge.
    /// Completion: `true` on HTTP 2xx, `false` on anything else (network
    /// error, non-2xx status, the main app not running).
    ///
    /// The `@Sendable` on `completion` matches URLSession's own
    /// completion-handler type; without it strict concurrency flags
    /// the capture of a non-Sendable closure into the `dataTask`
    /// closure below.
    private static func postToLoopback(urlString: String, completion: @escaping @Sendable (Bool) -> Void) {
        var request = URLRequest(url: loopbackURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: ["url": urlString])
        } catch {
            completion(false)
            return
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            let ok = error == nil
                && (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            completion(ok)
        }.resume()
    }

    /// Fallback when the main app's webserver isn't reachable: open the
    /// custom URL scheme, which re-launches the app and fires
    /// `AppDelegate.application(_:open:)`.
    private static func openAppViaURLScheme(urlString: String) {
        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .letters) ?? ""
        guard let url = URL(string: "synologydsmanager://download?downloadURL=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}
