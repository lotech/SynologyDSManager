# Safari Web Extension — source scaffolding

This directory is the source tree for the **Synology DS Manager Web
Extension** target. Phase 3b-1 (this PR) ships the source files only;
the Xcode target that compiles them lands in Phase 3b-2 so the two
surfaces can be reviewed independently.

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

### Phase 3b-2b — Web Extension Xcode target (still pending)

Needs Xcode's "New Target" wizard to land cleanly. pbxproj surgery
for a full new target is too fragile.

1. **Add the Web Extension target.** File → New → Target → macOS →
   Safari Extension App (Web Extension). Name:
   `SynologyDSManager WebExtension`. Bundle ID:
   `com.skavans.synologyDSManager.bridge` (must match
   `ClientAuthorization.allowedPeerBundleIdentifier`).
2. **Point the target at these source files.** Delete the files
   Xcode auto-generates inside the new target and drag-add the ones
   from this directory instead (`SafariWebExtensionHandler.swift`,
   `Info.plist`, `SynologyDSManager_WebExtension.entitlements`,
   everything under `Resources/`).
3. **Share `SynologyDSManager/Bridge/SynologyBridgeProtocol.swift`
   with the Web Extension target.** Check its target membership
   checkbox for the new target so both ends see the same @objc
   protocol.
4. **Embed the extension into the main app.** The Xcode template
   does this automatically (adds a Copy Files build phase to the
   main target with destination PlugIns/). Verify it after
   creating; it should slot in right next to the existing "Embed
   App Extensions" phase that carries the legacy target.
5. **Generate icons.** See `Resources/icons/README.md` for the
   `sips` one-liner that produces the three required PNGs from the
   legacy extension's PDF.

Phase 3c retires the legacy `SynologyDSManager Extension` target
and `Webserver.swift` once the Web Extension is shipping and
verified.
