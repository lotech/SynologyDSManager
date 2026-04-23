//
//  SynologyBridgeListener.swift
//  SynologyDSManager
//
//  Owns the `NSXPCListener` that accepts connections from the Safari
//  Web Extension's `SafariWebExtensionHandler`. Validates each
//  incoming connection via `ClientAuthorization` before exporting the
//  bridge API; refused peers never see a protocol method.
//
//  Phase 3b-2a state: the listener now advertises a named Mach
//  service. Reachability depends on the LaunchAgent plist bundled at
//  `Contents/Library/LaunchAgents/<name>.plist` being registered with
//  launchd — `AppDelegate` does that via `SMAppService.agent(plistName:)`
//  at first launch.
//
//  If the LaunchAgent isn't bundled (e.g. running from DerivedData
//  before 3b-2b wires the Copy Files build phase) or isn't approved
//  by the user, the listener still creates cleanly but simply never
//  receives connections — we're no worse off than the 3a anonymous
//  state. The main app keeps working; only the bridge is dark.
//
//  Phase 3b-2b (needs Xcode UI) still has to:
//    * Create the Safari Web Extension target itself (the XPC client).
//    * Add the Copy Files phase that embeds it into
//      `Contents/PlugIns/`.
//    * Add the Copy Files phase that embeds the LaunchAgent plist
//      into `Contents/Library/LaunchAgents/` (see pbxproj change
//      in this sub-phase for the partial wiring we could do from
//      the CLI).
//

import Foundation


/// Starts + retains the XPC listener that services
/// `SynologyBridgeProtocol` calls. Single instance stored as a global
/// in `AppDelegate` so the listener's lifetime matches the app's.
final class SynologyBridgeListener: NSObject, NSXPCListenerDelegate {

    /// Mach service name advertised to launchd via the bundled
    /// LaunchAgent plist. Must match the `Label` and `MachServices`
    /// entries in `SynologyDSManager/LaunchAgents/<name>.plist` and
    /// the `machServiceName` string used by the Web Extension's
    /// `SafariWebExtensionHandler`.
    static let machServiceName = "com.skavans.synologyDSManager.bridge"

    private let listener: NSXPCListener

    override init() {
        // Named listener advertising `machServiceName` to launchd.
        // Whether this name is actually reachable from outside depends
        // on the LaunchAgent plist being registered (see the class-
        // level doc comment). The listener itself creates cleanly
        // either way.
        self.listener = NSXPCListener(machServiceName: Self.machServiceName)
        super.init()
        self.listener.delegate = self
    }

    /// Begin listening for XPC connections. Call once at app launch.
    /// Safe to call more than once (subsequent calls are no-ops per
    /// NSXPCListener documentation).
    func start() {
        listener.resume()
        AppLogger.security.notice("SynologyBridgeListener resumed on Mach service \(Self.machServiceName, privacy: .public)")
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
