# CLAUDE.md

Orientation file for future Claude Code sessions working on this repo. If you're a
human, `README.md` is a better starting point.

## Modernisation status snapshot

- ✅ **Phase 0** — project hygiene, CI, SHA-pinned Actions, SECURITY.md
- ✅ **Phase 1** — macOS 13 floor, deprecated-API migration, `@main`
- ✅ **Phase 2** — all networking + storage rewritten: `SynologyAPI` actor on
  `URLSession`+`async/await`, typed Codable DTOs, SPKI pinning (TOFU),
  SecItem-based Keychain wrapper. Alamofire + SwiftyJSON + KeychainAccess
  all gone from `Package.resolved`. `SWIFT_STRICT_CONCURRENCY = complete`
  and the project builds warning-free. 23 unit tests run in CI on every PR.
- 🚧 **Phase 3** — Safari Web Extension + XPC bridge replacing the
  unauthenticated loopback HTTP server; Swifter dep goes with it.
  **3a + 3b shipped**: XPC scaffolding, the Web Extension source tree,
  the main-app-side Mach service wiring, the Web Extension Xcode target
  itself, and the bundled toolbar icons. Build-side path
  (Safari → extension handler → XPC → main app → DSM) is *structurally*
  functional — bundle installs cleanly, Safari lists the extension,
  pluginkit indexes it, ClientAuthorization + Mach service + LaunchAgent
  are all live. **Runtime is blocked**: Safari's WebExtension subsystem
  silently refuses to start the service worker (`background.js`) on
  macOS 26.x + Safari 26.x. See the *"Known blocker"* note below. Phase
  3c (retire the legacy target + `Webserver.swift`) waits on 3b's
  runtime coming up.
- ⏳ **Phase 4** — SwiftUI + Observation; retire `Shared.swift` globals.
- ⏳ **Phase 5** — release engineering (Sparkle, notarised DMGs via CI).

See `MODERNIZATION_PLAN.md` for the per-phase task checklist.

## Project at a glance

- **Product**: native macOS app + Safari extension that drives a Synology NAS's
  Download Station over its HTTP API.
- **Language / UI**: Swift 5.9, AppKit + Storyboards (plus one XIB-based
  `NSTableCellView`). No SwiftUI yet — moving there in Phase 4.
- **Min OS**: macOS 13 (app) / macOS 14 (test bundle, because Xcode 16's
  XCTest framework needs it).
- **Build system**: Xcode project (`SynologyDSManager.xcodeproj`), SwiftPM for
  dependencies. No `Package.swift`, no CocoaPods. Only remaining
  third-party SPM dep: **Swifter** (goes with `Webserver.swift` in Phase 3).
- **Targets**:
  - `SynologyDSManager` — main app
  - `SynologyDSManager Extension` — legacy Safari App Extension
    (deprecated format; retires in Phase 3c)
  - `SynologyDSManager WebExtension` — Safari Web Extension (source
    tree at `WebExtension/`, compiled as of Phase 3b-2b; bundle ID
    `com.skavans.synologyDSManager.bridge`)
  - `SynologyDSManagerTests` — macOS unit-test bundle hosted by the main
    app, `URLProtocol`-based fake transport, 23 tests of `SynologyAPI`

## Core files (main target)

| File | Role |
|---|---|
| `AppDelegate.swift` | `@main` entry point, handles URL-scheme deep links and `.torrent` file opens. Installs the TLS first-use approval handler. Retains the `SynologyBridgeListener`. |
| `Bridge/SynologyBridgeProtocol.swift` | `@objc` protocol exposed over XPC to the Safari Web Extension's `SafariWebExtensionHandler`. Currently one method: `enqueueDownload(url:reply:)`. Kept deliberately minimal so the wire surface stays easy to audit. Target-membership-shared with the Web Extension target so both sides compile against the same `@objc` definition. |
| `Bridge/SynologyBridgeService.swift` | `NSObject` implementation of `SynologyBridgeProtocol`. Validates incoming URLs (scheme allowlist, length cap), hops to `@MainActor` to read the global `synologyAPI`, and forwards to `SynologyAPI.createTask(url:)`. |
| `Bridge/SynologyBridgeListener.swift` | `NSXPCListener` + `NSXPCListenerDelegate` on the named Mach service `com.skavans.synologyDSManager.bridge`. Published to launchd via a bundled LaunchAgent plist + `SMAppService.agent(plistName:)` registration at launch. |
| `Bridge/ClientAuthorization.swift` | Peer code-signature validation via `auditToken` + `SecCodeCopyGuestWithAttributes` + `SecRequirementCreateWithString`. Refuses connections whose peer isn't our own native messaging host signed by our Team ID. |
| `Network/SynologyAPI.swift` | DSM API client. Actor-isolated, `URLSession` + `async/await`, typed errors, `_sid` in POST body (never URL). Add new endpoints here. |
| `Network/SynologyAPIModels.swift` | `Codable` DTOs for DSM responses. Keep 1:1 with DSM's wire format; translate into richer app types at the call site, not here. |
| `Network/SynologyTrustEvaluator.swift` | `URLSessionDelegate` that performs SPKI pinning (RFC 7469 "pin-sha256"). First-use fingerprints are handed to `firstUseDecision` for UI approval (TOFU); mismatches against an existing pin are refused outright. |
| `Network/SynologyError.swift` | Typed error surface (`SynologyError`) plus DSM-error-code→message mapping. Add new failure modes here, not `NSError`. |
| `Network/AppLogger.swift` | `os.Logger` categories — `network`, `auth`, `security`, `keychain`. Always use these; never `print(…)` in shipped code. |
| `Settings.swift` | `StoredCredentials` type + Keychain persistence via the in-house `KeychainStore`. Phase 2b replaced the KeychainAccess dependency with a direct `SecItem*` wrapper. |
| `KeychainStore.swift` | Thin `SecItem*` wrapper used by `Settings.swift`. `.whenUnlockedThisDeviceOnly` accessibility, service identifier `com.skavans.synologyDSManager`. |
| `Shared.swift` | Global mutable state (`synologyAPI`, `mainViewController`, `currentViewController`, etc.), annotated `nonisolated(unsafe)` under complete concurrency. Replaced by an `@Observable` app model in Phase 4. |
| `Webserver.swift` | Loopback HTTP server on port 11863 used by the Safari extension to enqueue downloads. **Unauthenticated** — scheduled for removal in Phase 3 in favour of `NSXPCConnection`. |
| `ViewControllers/` | Cocoa view controllers, one per screen. |
| `DestinationView.swift`, `DownloadsCellView.swift`, `LoadableView.swift` | Custom `NSView` subclasses loaded from XIB. |
| `LaunchAgents/com.skavans.synologyDSManager.bridge.plist` | launchd plist bundled at `Contents/Library/LaunchAgents/` that advertises the bridge's Mach service name. Registered programmatically via `SMAppService.agent(plistName:)` at first launch. |

## Web Extension source (`WebExtension/`)

Source tree for the Safari Web Extension target. See
`WebExtension/README.md` for detail. Headlines:

- `SafariWebExtensionHandler.swift` — the extension's
  `NSExtensionPrincipalClass`. Opens an `NSXPCConnection` to the main
  app's bridge, forwards one call, replies back to JS. Uses a
  `CheckedContinuation` + `UncheckedBox<T>` pattern so the `@Sendable`
  XPC reply closure doesn't capture `NSExtensionContext` /
  `NSXPCConnection` / `self` across an isolation boundary.
- `Resources/manifest.json` — MV3 manifest. `permissions`:
  `contextMenus` + `nativeMessaging`. Declares a toolbar `action`
  (required to keep Safari's service worker alive — see runtime
  blocker below), a background `service_worker`, and
  `browser_specific_settings.safari.strict_min_version = 16.4`.
- `Resources/background.js` — registers the `contexts: ["link"]`
  context-menu and dispatches link URLs to the native handler.
  Defensively wraps every API touch in try/catch so a single
  missing-API throw can't take down the service worker;
  registration fires on `onInstalled`, `onStartup`, and module-scope
  startup.
- `Resources/_locales/en/messages.json` — i18n strings. Shipped
  via a **folder reference** (not a group) in `project.pbxproj` so
  the bundle preserves `_locales/en/messages.json` hierarchy; with
  a group, Xcode flattens to `Resources/messages.json` and Safari
  can't resolve `__MSG_*` placeholders.
- `Resources/icons/` — `toolbar-{48,96,128}.png`, derived at build
  time by Lanczos-downsampling the main app's
  `Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png`. Also
  shipped as a folder reference for the same hierarchy-preservation
  reason; the manifest's `icons` key references `icons/toolbar-*.png`
  and Safari fails the lookup if they're flat.
- `Info.plist` + `SynologyDSManager_WebExtension.entitlements` —
  extension point + sandbox config. The Web Extension target has
  `ENABLE_DEBUG_DYLIB = NO` explicitly set (both configurations);
  the Xcode-15+ default of `YES` produces a stub `Contents/MacOS/`
  executable that Safari's WebExtensionHandler can't follow.

### Known blocker — Safari refuses to start the service worker (Phase 3b-2b-RT)

Observed on macOS 26.x / Safari 26.x. After all of the above —
folder references correct, `ENABLE_DEBUG_DYLIB=NO`, `action`
declared, bundle codesign valid, pluginkit indexing clean,
principal class compiled and resolvable — Safari's WebExtension
subsystem silently refuses to execute `background.js`. Symptoms:

- Safari → Settings → Extensions lists the extension correctly
  (real name, real description, real icon, the expected
  permissions breakdown).
- Safari → Develop → Web Extension Background Content shows
  `Synology DS Manager (not loaded)` — sometimes present,
  sometimes absent, alternating every few minutes.
- Clicking `(not loaded)` does nothing; no Web Inspector window
  opens for the worker.
- Attaching to whatever cold worker context the Inspector
  reaches gives `typeof browser === "object"` and
  `Object.keys(browser.runtime) === []` — the WebExtension APIs
  never populate.
- `log stream` with a wide predicate produces no entry from
  WebExtensionHandler / extensionkitservice that mentions our
  bundle ID — Safari isn't trying and failing, it's not trying
  at all.
- Verified identical behaviour via `./deploy.sh → i` install
  path **and** `⌘R` from Xcode, ruling out the install flow.
- Minimal manifest (manifest_version, name, description,
  version, `background.service_worker` — nothing else)
  reproduces the symptom; it's below the manifest layer.
- Reference extensions (1Password for Safari, etc.) run fine in
  the same Safari, so the WebExtension runtime itself is alive.

Runtime bring-up tracked as a separate follow-up. Everything
upstream of this — target compile, `.appex` embed, install,
signing, pluginkit registration, ClientAuthorization, Mach
service, LaunchAgent registration — all works as designed.

## Conventions

- **No `print` for diagnostics** — use `os.Logger` via `AppLogger` with a
  subsystem of `com.skavans.synologyDSManager`.
- **No force-unwraps / force-tries** on network data. Validate at system
  boundaries, propagate typed errors upward. SwiftLint is configured to warn
  on `!` and `try!` (`force_unwrapping`, `force_try`).
- **No Alamofire / SwiftyJSON** — both were removed in Phase 2a-2d. Use
  `URLSession` + `async/await` and `Codable`.
- **Keychain access** must use `.whenUnlockedThisDeviceOnly` accessibility at
  minimum. Never persist session IDs across launches.
- **TLS**: never disable trust evaluation. Self-signed NAS certs are handled
  via explicit, user-confirmed SPKI pinning in `SynologyTrustEvaluator`.
- **Logging**: never log passwords, OTP codes, session IDs, or full request
  URLs / bodies containing `_sid`.
- **Concurrency**: `SWIFT_STRICT_CONCURRENCY = complete`. Actor-isolated
  state lives inside `SynologyAPI`; the rest of the app is effectively
  main-thread-only. Globals in `Shared.swift` are `nonisolated(unsafe)` —
  don't add more.

## Commands

Most day-to-day maintainer tasks go through the interactive helper:

```sh
./deploy.sh
```

…which offers single-key options for pulling `main`, opening in Xcode,
configuring signing, installing to `/Applications`, and building a
distributable DMG (optionally notarised). See the top of `deploy.sh` for the
key bindings. Underneath, the script just calls the commands below.

```sh
# Resolve Swift Package dependencies headlessly:
xcodebuild -project SynologyDSManager.xcodeproj \
  -scheme SynologyDSManager \
  -resolvePackageDependencies

# Build (unsigned) from the command line — CI uses this exact invocation:
xcodebuild -project SynologyDSManager.xcodeproj \
  -scheme SynologyDSManager \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build

# Lint:
swiftlint

# Format check:
swiftformat --lint .
```

### Running the tests

Automated tests live in `SynologyDSManagerTests/` and cover `SynologyAPI`
using a `URLProtocol`-based fake transport (no network, no real NAS
required). Run from the command line:

```sh
xcodebuild test -project SynologyDSManager.xcodeproj \
  -scheme SynologyDSManager \
  -destination 'platform=macOS'
```

Or from Xcode: ⌘U.

### Test target layout

The `SynologyDSManagerTests` target is a macOS unit-test bundle hosted
by the main app. Notable pbxproj settings:

- `SDKROOT = macosx`, `SUPPORTED_PLATFORMS = macosx`,
  `SUPPORTS_MACCATALYST = NO` — pure macOS, not Mac Catalyst. Xcode 16+
  would otherwise prefer Catalyst and fail module resolution against the
  pure-macOS app module.
- `MACOSX_DEPLOYMENT_TARGET = 14.0` — higher than the app's `13.0`
  floor because Xcode 16's XCTest is built against 14.0+. Tests only
  run during development, so bumping the floor here is fine.
- `TEST_HOST = $(BUILT_PRODUCTS_DIR)/SynologyDSManager.app/Contents/MacOS/SynologyDSManager`
  and `BUNDLE_LOADER = $(TEST_HOST)` — the bundle loads into the app
  binary at runtime and links against its symbols at build time.
- PBXTargetDependency on the main app, so the app builds first.
- No hardcoded `DEVELOPMENT_TEAM` — signing inherits from the
  gitignored `Signing.local.xcconfig` via the xcconfig cascade, same
  as the other two targets.

If Xcode ever re-injects `DEVELOPMENT_TEAM = <your-id>` into
`project.pbxproj` (it sometimes does on project open), strip it out
before committing. The xcconfig cascade exists specifically to keep
Team IDs out of the public repo.

## Code signing

Signing is driven by an **xcconfig cascade** so no Team ID ever lands in the
public repo:

- `Signing.xcconfig` (committed, no secrets) — defines defaults:
  `Apple Development` for Debug, `Developer ID Application` for Release,
  `CODE_SIGN_STYLE = Automatic`, and a trailing `#include? "Signing.local.xcconfig"`.
- `Signing.local.xcconfig` (gitignored, per-developer) — sets the single
  variable that matters: `DEVELOPMENT_TEAM`.
- `Signing.local.xcconfig.template` (committed) — the file maintainers copy
  to create their own `Signing.local.xcconfig`.

The xcconfig is wired as `baseConfigurationReference` on the project-level
build configurations, so both Xcode GUI builds and `xcodebuild` from the
command line pick it up automatically.

**Do not** re-introduce `DEVELOPMENT_TEAM = …` in `project.pbxproj`,
hard-code a specific identity name, or commit `Signing.local.xcconfig`.

To set up a new maintainer machine: run `./deploy.sh` → `s`.

## Public-repo best practices

This repo is public. Every commit, every issue, every CI log is world-readable.
When in doubt, leak nothing.

**Never commit:**
- Apple Developer Team IDs, provisioning profiles, `.p12`/`.cer` files, App
  Store Connect API keys, notarisation credentials. `Signing.local.xcconfig`
  and `.notary-profile-name` are already gitignored — keep them that way.
- `.env` files, SSH keys, AWS/GCP tokens, Slack/Discord webhooks.
- `xcuserdata/`, `DerivedData/`, `.DS_Store`, editor-local configs.
- Real Synology NAS credentials, even in test fixtures. Use obvious
  placeholders (`user@example.com`, `ABCDE12345`).

**When logging, screenshotting, or pasting into issues:**
- Redact `_sid=…`, cookies, `Authorization` headers, session IDs, and any
  query string that might contain a password or OTP.
- Redact LAN IPs, DDNS hostnames, and QuickConnect IDs — they identify a
  specific user's NAS.
- Sample issue-tracking stance: if the issue template doesn't have a redaction
  reminder, add one before merging the template change.

**When accepting contributions:**
- Review diffs for hard-coded secrets before approving PRs. GitHub's
  secret-scanning catches a lot but not everything.
- Pin third-party GitHub Actions by commit SHA, not by tag. Tags are
  mutable; SHAs are not.
- Prefer SwiftPM dependencies that are themselves open-source and actively
  maintained. Commit `Package.resolved` so CI reproduces exact versions.
- Never run `curl | sh` in CI or in any script we ship.

**Releases:**
- Tag releases (`v2.0.0`, `v2.1.0`, …) and cut them through GitHub Releases,
  not by pushing binaries directly to `main`.
- Sign *and* notarise distribution builds before attaching them to a release.
  An unsigned `.app` off GitHub will trigger Gatekeeper prompts on every user
  machine.
- Never force-push `main`. Never skip commit hooks (`--no-verify`) unless the
  hook itself is broken and you're fixing it in the same PR.

**Security disclosures:**
- Accept reports via GitHub Security Advisories (private), not public issues.
- Keep a brief `SECURITY.md` policy at the repo root (planned as a Phase 0
  follow-up).

## How to land a change

1. Work on a feature branch; never push directly to `main`.
2. Add a bullet under `## [Unreleased]` in `CHANGELOG.md` describing the
   user-visible effect (not the mechanical diff).
3. If the change affects or completes a task from `MODERNIZATION_PLAN.md`,
   tick the corresponding checkbox and update the phase status if all tasks
   in the phase are done.
4. Open a PR against `main` using the template.
5. CI runs build + SwiftLint + SwiftFormat check (the lint/format jobs are
   non-blocking today — they become blocking once the repo is fully
   formatted, tracked as a Phase 0 follow-up task).

## Important security notes to remember

- The loopback webserver in `Webserver.swift` is **unauthenticated** and
  accepts any local POST. Do not extend it — prefer XPC.
- The `synologydsmanager://` URL scheme is trusted by `AppDelegate` without
  validation. Do not widen what it accepts until Phase 3.
- `SynologyClient` currently ships credentials/SIDs in URL query strings;
  don't add new call sites that follow this pattern.

## Where the modernisation plan lives

[`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md) — phased roadmap with a
checklist per phase. Keep it up to date as work lands.
