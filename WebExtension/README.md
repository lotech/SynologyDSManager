# Safari Web Extension

This directory is the source tree for the **Synology DS Manager Web
Extension** target — a Safari MV3 extension that captures link
right-clicks and dispatches the URL to the main app over XPC. The
source landed in Phase 3b-1 and the Xcode target that compiles it
landed in Phase 3b-2b.

## Why Web Extensions, not Safari App Extensions

The legacy `SynologyDSManager Extension` target uses the
`com.apple.Safari.extension` extension point — Apple's Safari App
Extension format, deprecated since Safari 14 (macOS 11) in favour of
the cross-browser Web Extension standard. Moving to `Safari Web
Extension` shape gets us:

- MV3 `manifest.json` + `browser.*` APIs — same surface as Chrome and
  Firefox, so any future cross-browser work is cheap.
- `browser.contextMenus` with `contexts: ["link"]` replaces the
  content-script trick of walking up from the click target to find
  the enclosing `<a>`.
- A proper sandboxed process boundary between the JavaScript and the
  Swift `SafariWebExtensionHandler` that opens the XPC connection.

## Layout

| Path | What it is |
|---|---|
| `SafariWebExtensionHandler.swift` | The extension's `NSExtensionPrincipalClass`. Runs in the extension's sandboxed process and bridges `browser.runtime.sendNativeMessage` calls to the main app over `NSXPCConnection(machServiceName:)`. |
| `Resources/manifest.json` | MV3 manifest. Declares permissions, the background service worker, and Safari minimum version (16.4 — the first Safari release with full MV3 support). |
| `Resources/background.js` | Service worker. Registers the right-click context-menu on links and dispatches the chosen URL to the native handler. |
| `Resources/_locales/en/messages.json` | i18n strings. Extension display name, description, context-menu title. |
| `Resources/icons/` | PNG toolbar icons (Phase 3b-2 populates these from the legacy PDF — see that directory's `README.md`). |
| `Info.plist` | Declares `NSExtensionPointIdentifier = com.apple.Safari.web-extension` and the principal Swift class. |
| `SynologyDSManager_WebExtension.entitlements` | Sandbox entitlements. Includes a `mach-lookup.global-name` exception for the bridge's Mach service so the sandboxed process can reach it. |

## How a click flows through the system

```
   [User right-clicks a link in Safari]
                │
                ▼
   background.js service worker
     │  browser.runtime.sendNativeMessage(appID, {action, url})
     ▼
   SafariWebExtensionHandler.beginRequest(with:)   ← same extension bundle
     │  NSXPCConnection(machServiceName: "…bridge")
     ▼
   SynologyBridgeListener  (in main app)
     │  ClientAuthorization.isTrusted(connection:)   ← Phase 3a gate
     ▼
   SynologyBridgeService.enqueueDownload(url:reply:)
     │  synologyAPI.createTask(url:)
     ▼
   [Synology NAS Download Station]
```

The XPC boundary is where network credentials stop. The handler
never has the NAS host, username, password, or session ID — it only
sees the URL to enqueue and a success/failure reply.

## Phase 3b-2 status

### Phase 3b-2a — main-app-side wiring (shipped)

Done from the CLI; requires no Xcode UI work:

- ✅ Main app's XPC listener switched from
  `NSXPCListener.anonymous()` to
  `NSXPCListener(machServiceName: "com.skavans.synologyDSManager.bridge")`.
- ✅ `AppDelegate.applicationWillFinishLaunching` calls
  `SMAppService.agent(plistName:).register()` once per launch.
  Idempotent and diagnostic-only on failure — missing plist or
  unapproved login item degrades gracefully (listener is simply
  unreachable from outside, main app works as before).
- ✅ `project.pbxproj` adds an "Embed LaunchAgents" Copy Files build
  phase on the main target that ships
  `SynologyDSManager/LaunchAgents/com.skavans.synologyDSManager.bridge.plist`
  into `Contents/Library/LaunchAgents/` at build time.

### Phase 3b-2b — Web Extension Xcode target (shipped)

Landed via Xcode's "New Target" wizard rather than pbxproj surgery.
Kept here as a reference for anyone redoing the target on a fork,
or for future similar work. Each step is a ✅:

1. **Added the Web Extension target.** File → New → Target → macOS →
   Safari Extension App (Web Extension). Name:
   `SynologyDSManager WebExtension`. Bundle ID:
   `com.skavans.synologyDSManager.bridge` (must match
   `ClientAuthorization.allowedPeerBundleIdentifier`).
2. **Pointed the target at these source files.** Deleted the files
   Xcode auto-generated inside the new target and reference-added
   the ones from this directory (`SafariWebExtensionHandler.swift`,
   `Info.plist`, `SynologyDSManager_WebExtension.entitlements`,
   everything under `Resources/`). Required turning off
   `GENERATE_INFOPLIST_FILE` so our hand-authored `Info.plist` is
   used verbatim — the `NSExtension` dict is load-bearing and a
   synthesised plist can clobber it.
3. **Shared `SynologyDSManager/Bridge/SynologyBridgeProtocol.swift`
   with the Web Extension target** via target-membership checkbox.
   Both sides compile it into their own module; `NSXPCConnection`
   matches by the Obj-C runtime name of the `@objc` protocol, so
   the wire format stays in sync.
4. **Embed-into-main-app** slot: Xcode auto-added
   `SynologyDSManager WebExtension.appex` to the main target's
   existing "Embed App Extensions" Copy Files phase
   (`Contents/PlugIns/`), right next to the legacy extension.
5. **Generated icons.** Two-step `sips` pipeline (see
   `Resources/icons/README.md`) — single-step `sips -Z N input.pdf`
   is a no-op on PDF input in current macOS, so we rasterise to a
   temporary high-res PNG then `-z H W` to each target size.
6. **Normalised target build settings** to match the main app's
   signing cascade. The wizard injected `CODE_SIGN_IDENTITY` and
   `CODE_SIGN_STYLE` at target level, which short-circuits the
   per-configuration logic in `Signing.xcconfig`; stripping both
   lets the xcconfig drive signing the same way it drives the main
   app. Also normalised `CURRENT_PROJECT_VERSION`,
   `MARKETING_VERSION`, and `MACOSX_DEPLOYMENT_TARGET` to match the
   parent, and removed the wizard's stale `INFOPLIST_KEY_*` keys.

Phase 3c retires the legacy `SynologyDSManager Extension` target
and `Webserver.swift` once the Web Extension is shipping and
verified.
