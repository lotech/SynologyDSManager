//
//  SynologyBridgeListener.swift
//  SynologyDSManager
//
//  Owns the `NSXPCListener` that accepts connections from the native
//  messaging host. Validates each incoming connection via
//  `ClientAuthorization` before exporting the bridge API; refused
//  peers never see a protocol method.
//
//  Phase 3a state: the listener is started in anonymous mode. Nothing
//  outside the app can reach it because no Mach service name is
//  registered. It's there ready for Phase 3b, which:
//
//    * Adds the native messaging host target (small Swift CLI bundled
//      inside the app).
//    * Adds a `LaunchAgent` plist bundled in the app that registers a
//      Mach service name pointing at the main-app binary.
//    * Swaps the anonymous listener below for one created via
//      `NSXPCListener(machServiceName:)` — same delegate, same
//      authorisation, same service object, just reachable
//      externally.
//

import Foundation


/// Starts + retains the XPC listener that services
/// `SynologyBridgeProtocol` calls. Single instance stored as a global
/// in `AppDelegate` so the listener's lifetime matches the app's.
final class SynologyBridgeListener: NSObject, NSXPCListenerDelegate {

    private let listener: NSXPCListener

    override init() {
        // Anonymous listener: not reachable from outside the app yet.
        // Phase 3b replaces this with `NSXPCListener(machServiceName:)`
        // once the LaunchAgent plist is bundled.
        self.listener = NSXPCListener.anonymous()
        super.init()
        self.listener.delegate = self
    }

    /// Begin listening for XPC connections. Call once at app launch.
    /// Safe to call more than once (subsequent calls are no-ops per
    /// NSXPCListener documentation).
    func start() {
        listener.resume()
        AppLogger.security.notice("SynologyBridgeListener started (anonymous; Phase 3b adds Mach service registration)")
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Refuse any peer whose code signature doesn't match our
        // expected native-messaging-host identity. Without this check
        // a public NSXPCListener is callable by any local process.
        guard ClientAuthorization.isTrusted(connection: newConnection) else {
            // Logging handled inside ClientAuthorization.
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: SynologyBridgeProtocol.self)
        newConnection.exportedObject = SynologyBridgeService()

        // Log end-of-connection once — useful when debugging why a
        // Safari-extension invocation didn't land.
        newConnection.invalidationHandler = {
            AppLogger.security.notice("Bridge connection invalidated")
        }
        newConnection.interruptionHandler = {
            AppLogger.security.notice("Bridge connection interrupted")
        }

        newConnection.resume()
        return true
    }
}
