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
| `Resources/icons/` | `toolbar-48.png`, `toolbar-96.png`, `toolbar-128.png` — derived from the main app's `AppIcon` at build time of Phase 3b-2. `icons/` is a folder reference (not a group) so the bundle preserves the subdirectory, matching the manifest's `icons/toolbar-*.png` keys. |
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
5. **Generated icons.** Downsampled from the main app's
   `Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png` (a
   256×256 RGBA PNG) with Lanczos resampling to 48/96/128. First
   attempt tried rasterising `SynologyDSManager Extension/ToolbarItemIcon.pdf`
   via `sips`, but that PDF is an AppKit *template* image (opaque
   black on transparent, designed for runtime tinting by macOS)
   and Safari's Extensions panel renders Web Extension icons
   as-is without tinting, which showed as a solid black square.
   The main app's AppIcon is the same artwork the user already
   sees in the dock / LaunchAgents list, so the Web Extension
   now matches.
6. **Normalised target build settings** to match the main app's
   signing cascade. The wizard injected `CODE_SIGN_IDENTITY` and
   `CODE_SIGN_STYLE` at target level, which short-circuits the
   per-configuration logic in `Signing.xcconfig`; stripping both
   lets the xcconfig drive signing the same way it drives the main
   app. Also normalised `CURRENT_PROJECT_VERSION`,
   `MARKETING_VERSION`, and `MACOSX_DEPLOYMENT_TARGET` to match the
   parent, and removed the wizard's stale `INFOPLIST_KEY_*` keys.

Also landed in follow-up commits on top of 3b-2b:

- `ENABLE_DEBUG_DYLIB = NO` on the Web Extension target (both
  Debug and Release). Xcode 15+ defaults Debug builds to
  producing a stub `Contents/MacOS/` executable that loads the
  real code from a sibling `.debug.dylib` at launch. Safari's
  WebExtensionHandler can't follow the indirection and silently
  drops the service worker on the floor.
- Folder references (not groups) for `_locales/` and `icons/`
  in `project.pbxproj`. With groups, Xcode flattens the bundle
  layout at build time (`messages.json` and `toolbar-*.png`
  all land directly in `Contents/Resources/`), which breaks
  MV3's `default_locale` / `icons.*` lookups. Folder references
  preserve the subdirectory hierarchy verbatim.
- Toolbar `action` block in `manifest.json` and a minimal
  `browser.action.onClicked` handler. The button exists mainly
  so Safari treats the extension as "interactive" and
  consistently starts the service worker on install/update.
- Defensive `background.js` — every API touch wrapped in
  try/catch, registration retried on `onInstalled`, `onStartup`,
  and module-scope load, so one missing API can't take down the
  worker on load.
- `deploy.sh` builds Debug for local installs (Release is
  reserved for the DMG pipeline that feeds notarisation), and
  explicitly `pluginkit -r`s the build-tree `.appex` copies
  after `cp -R` into `/Applications/` so Safari doesn't see the
  same extension registered twice.

## Phase 3b-2b-RT — Safari won't start the service worker (known blocker)

Observed on macOS 26.x / Safari 26.x after all of the above
landed. The bundle is structurally valid — principal class
resolves, `pluginkit` indexes it, Gatekeeper accepts the host
app, codesign strict-verify passes, all the MV3 boxes are
ticked — yet Safari never executes `background.js`. Develop →
Web Extension Background Content alternates between listing
the extension as `(not loaded)` and not listing it at all;
clicking the entry doesn't open a live Inspector window; a
cold Inspector console attached to whatever partial context
Safari creates shows `typeof browser === "object"` but
`Object.keys(browser.runtime) === []`. No log predicate
against `Safari`, `extensionkitservice`, or the
`WebExtension` subsystem surfaces any mention of our bundle —
Safari isn't trying and failing, it simply doesn't try.

A minimal MV3 manifest (manifest_version, name, description,
version, `background.service_worker` — nothing else) reproduces
the symptom, so this isn't a manifest-content problem. Other
Safari Web Extensions in the same browser (1Password,
AdGuard, etc.) run fine, so the WebExtension runtime itself
is healthy.

Tracked as **Phase 3b-2b-RT** in `MODERNIZATION_PLAN.md`.
Next diagnostic step is a clean-room Safari Web Extension
created from Xcode's built-in template (zero modifications),
installed via the same flow, to see whether *any* locally-built
extension can start its worker on this machine — which either
(a) gives us a working reference to binary-search forward
against our bundle, or (b) proves the local Safari install is
in a state where no extensions can launch, independent of
this project.

Phase 3c retires the legacy `SynologyDSManager Extension`
target and `Webserver.swift` once 3b-2b-RT is resolved and the
Web Extension is shipping in earnest.
