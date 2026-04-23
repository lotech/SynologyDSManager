# Modernisation plan

Living document. Tick boxes as tasks land. When all tasks in a phase are
complete, move the phase status from **In progress** / **Planned** to
**Shipped** with the date.

Last updated: 2026-04-23 (Phase 3b-1 pushed — Safari Web Extension scaffolding)

---

## Phase 0 — Project hygiene · **In progress**

Goal: a clean, lintable, CI-backed baseline for everything that follows.

- [x] Remove `xcuserdata` from version control (`git rm -r --cached`)
- [x] Bump `objectVersion` (52 → 56), `compatibilityVersion` (Xcode 9.3 →
      Xcode 14.0), `LastUpgradeCheck` (1130 → 1520)
- [x] Remove stale `DEVELOPMENT_TEAM = GVS9699BGK` from both targets' build
      configs
- [x] Remove dead `FRAMEWORK_SEARCH_PATHS` entries referencing an absent
      `Sparkle Updater` directory
- [x] Remove unused `StoreKit.framework` reference (was left over from the
      paid-app IAP)
- [x] Tighten the Alamofire package pin (was `5.0.0-rc.3`) — stopgap until
      Phase 2 removes Alamofire entirely
- [x] Add `.swiftlint.yml`, `.swiftformat`, `.swift-version`
- [x] Add a GitHub Actions CI workflow (build + lint + format check)
- [x] Add `CODEOWNERS`, PR template, bug-report / feature-request /
      security-report issue templates
- [x] Rewrite `README.md` for the forked, maintained state
- [x] Add `CLAUDE.md`, `MODERNIZATION_PLAN.md`, `CHANGELOG.md`
- [x] Document public-repo best practices in `CLAUDE.md` (secrets handling,
      log redaction, release/signing discipline)
- [x] Add `deploy.sh` single-key maintainer menu (pull main / open in Xcode /
      configure signing / install to Applications / create DMG)
- [x] Set up `Signing.xcconfig` + gitignored `Signing.local.xcconfig` so
      Apple Developer Team IDs stay out of the public repo, with the
      xcconfig wired as `baseConfigurationReference` in `project.pbxproj`
- [x] Add a `SECURITY.md` policy at the repo root referencing GitHub Security
      Advisories for private disclosure
- [x] Pin third-party GitHub Actions by commit SHA (was `actions/checkout@v4`,
      now pinned to `@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1`)
- [ ] Flip SwiftLint / SwiftFormat CI jobs to blocking once the repo is
      fully formatted (follow-up PR)

## Phase 1 — Platform baseline · **In progress**

Goal: compile cleanly against modern Xcode on a modern macOS deployment
target, replacing the deprecated APIs we can do without further design work.

- [x] Raise `MACOSX_DEPLOYMENT_TARGET` 10.13 → 13.0 (both targets)
- [x] Remove blanket `NSAllowsArbitraryLoads = true` from the main
      `Info.plist`
- [x] Replace `@NSApplicationMain` with `@main` in `AppDelegate`
- [x] Replace `NSUserNotification` + `NSUserNotificationCenter` with
      `UNUserNotificationCenter` + `UNNotificationRequest` (incl. a single
      authorisation request on launch)
- [x] Replace `NSOpenPanel.allowedFileTypes` (deprecated) with
      `allowedContentTypes: [UTType]`
- [x] Fix `protocol LoadableView: class` → `AnyObject`
- [x] Enable `SWIFT_STRICT_CONCURRENCY = minimal` (will be bumped to
      `complete` after Phase 2)
- [ ] Remove the dead `registerEvent(…)` analytics stub — blocked until the
      networking rewrite touches every call site (Phase 2)
- [ ] Remove the `swiftapps.skavans.ru` mailto and `synoboost.com` link from
      Settings / BT Search — Phase 4 when we rewrite those screens

## Phase 2 — Networking & storage rewrite · **Shipped · 2026-04-23**

Goal: no Alamofire, no SwiftyJSON, typed models, proper TLS, properly
scoped Keychain access.

### Phase 2a-1 — Networking foundation (merged)

- [x] Introduce a `SynologyAPI` actor backed by `URLSession` + `async/await`
      (`SynologyDSManager/Network/SynologyAPI.swift`)
- [x] Define `Codable` models for DSM responses, replacing ad-hoc
      `JSON()` access (`SynologyDSManager/Network/SynologyAPIModels.swift`)
- [x] Replace `DisabledEvaluator()` with opt-in SPKI pinning of the NAS's
      leaf certificate; on first connect, hand the observed fingerprint to
      the UI for explicit user approval, with the pin persisted thereafter
      (`SynologyDSManager/Network/SynologyTrustEvaluator.swift`)
- [x] Move `_sid` out of URL query strings (session cookie, form body on
      `SYNO.API.Auth logout`)
- [x] Typed error surface (`SynologyError`) with DSM error-code → message
      mapping (`SynologyDSManager/Network/SynologyError.swift`)
- [x] `os.Logger` categories for network / auth / security / keychain
      (`SynologyDSManager/Network/AppLogger.swift`)

### Phase 2a-2a — Settings migration + cert-approval UI (merged)

- [x] Hoist the TLS trust evaluator to a shared `synologyTrustEvaluator`
      singleton in `Shared.swift`, so pins persist across reconstructions
      of the client and the approval callback can be installed once
- [x] Replace `SynologyTrustEvaluator.pendingApproval` with a blocking
      `firstUseDecision` callback that the evaluator awaits on the
      URLSession delegate queue before completing the trust challenge
- [x] Install an `NSAlert`-based first-use approval handler in
      `AppDelegate.applicationWillFinishLaunching`; dialog shows the
      fingerprint and offers Trust / Cancel
- [x] Add a parallel `synologyAPI: SynologyAPI?` global in `Shared.swift`
      so migration can proceed call-site by call-site
- [x] Migrate `SettingsViewController.testConnectionButtonClicked` to use
      `SynologyAPI.authenticate()` via `Task { @MainActor … }`; the
      legacy client is still bootstrapped after a successful test so the
      rest of the app keeps working
- [x] `DownloadsViewController.doWork` now initialises both
      `synologyClient` and `synologyAPI` from the same settings

### Phase 2a-2b — DownloadsViewController migration (merged)

- [x] Replace `SynologyClient.getDownloads` call with
      `SynologyAPI.listTasks()` in the refresh loop
- [x] Replace `pauseDownload` / `resumeDownload` / `deleteDownload` call
      sites with `pauseTask` / `resumeTask` / `deleteTask`
- [x] Stop iterating `JSON?` in `refreshDownloads`; use typed `[DSMTask]`
      end-to-end (and drop `import SwiftyJSON` from
      `DownloadsViewController.swift`)
- [x] Move the refresh timer off `Timer.scheduledTimer` onto an `async`
      polling loop (`refreshTask: Task<Void, Never>?`) that obeys
      `Task.isCancelled` and re-cancels on repeat `doWork` calls
- [x] Set `workStarted = true` at the end of `doWork` so repeat
      credentials changes take the Settings else-branch rather than
      re-invoking `doWork` (was a latent bug: the flag was never set,
      so every Test Connection re-created the client and stacked a
      fresh 3-second timer)
- [x] Mirror the Settings else-branch on `SynologyAPI`:
      `updateCredentials` + `authenticate` after a credentials change,
      not just on the legacy client

### Phase 2a-2c — Add / Search / Destination view controllers (merged)

- [x] `AddDownloadViewController`: migrate URL + torrent-file enqueue
      paths to `SynologyAPI.createTask`. Actions now run in a detached
      `Task` that survives the window closing.
- [x] `BTSearchController`: rewrote on `SynologyAPI.searchTorrents`.
      Dropped `import SwiftyJSON` and the `searchResultsJSON: JSON?`
      state; now uses `[BTSearchResult]` plus a `selectedIDs: Set<String>`
      for checkbox state. The `Timer.scheduledTimer` nested poll loop
      is gone — the actor's own cancellable poll handles it. The
      running search is cancelled when the window closes.
- [x] `ChooseDestViewController`: migrated directory listing to
      `SynologyAPI.listDirectories`. Moved the `RemoteDir` class here
      from `SynologyClient.swift` (local to this view controller;
      nothing else uses it).
- [x] `DestinationView`: dropped SwiftyJSON; the persisted
      `downloadDestinations` UserDefaults blob is now
      encoded/decoded via `JSONEncoder`/`JSONDecoder` in a format
      backward-compatible with the SwiftyJSON output.
- [x] `DownloadsViewController.downloadByURLFromExtension`: migrated
      to `SynologyAPI.createTask`. (The webserver that calls it is
      still scheduled for removal in Phase 3.)
- [x] Removed the transitional `synologyClient.authenticate` / settings
      assignments in `DownloadsViewController.doWork` and
      `SettingsViewController`. The legacy `SynologyClient` is no
      longer reachable from any view controller; its deletion lands
      in Phase 2a-2d.
- [x] Added `URLProtocolStub`-backed tests for the API methods these
      migrations depend on: `createTask(url:)` (payload shape + nil
      destination omission), `searchTorrents` (poll-until-done
      behaviour, request order), and `listDirectories` (typed decoding
      + null-files resilience).

### Phase 2a-2d — Test target (in progress; moved ahead of 2a-2c)

- [x] Add `SynologyDSManagerTests/URLProtocolStub.swift` (request
      interception + form-body capture + multi-step response queueing)
- [x] Add `SynologyDSManagerTests/SynologyAPITests.swift` covering
      authenticate success/failure, listTasks typed decoding,
      pause/resume/delete payload shape, HTTP/decoding/transport error
      paths, updateCredentials session invalidation, logout, and
      SynologyErrorCode mapping. Includes explicit regression guards
      for the two 2a-2b regressions (`_sid` must be in POST body; SID
      must NEVER appear in a URL query string)
- [x] Make `SynologyAPI.init` accept an optional
      `URLSessionConfiguration` so tests can register
      `URLProtocolStub.self` as a `protocolClass` without touching
      the production code path
- [x] Wire the `SynologyDSManagerTests` target into the Xcode project.
      Target reshaped as a pure-macOS unit-test bundle (`SDKROOT = macosx`,
      `SUPPORTED_PLATFORMS = macosx`, `SUPPORTS_MACCATALYST = NO`,
      `MACOSX_DEPLOYMENT_TARGET = 14.0` for XCTest), `TEST_HOST` +
      `BUNDLE_LOADER` pointing at the app binary, `PBXTargetDependency`
      on the app, scheme updated to build both targets for Test. Also
      stripped five `DEVELOPMENT_TEAM = <team-id>` lines Xcode had
      injected during target creation — signing now inherits from the
      `Signing.xcconfig` cascade.
- [x] Add a CI job that runs `xcodebuild test`.

### Phase 2a-2d — Cleanup (merged)

- [x] Deleted `SynologyDSManager/SynologyClient.swift` (the legacy
      Alamofire-based client, ~300 lines of dead code).
- [x] Removed Alamofire from `Package.resolved` + `project.pbxproj`
      (both targets). Migrated `SafariExtensionHandler.swift` off
      Alamofire onto `URLSession`.
- [x] Removed SwiftyJSON from `Package.resolved` + `project.pbxproj`.
      Rewrote `Settings.swift` on `JSONEncoder`/`JSONDecoder` (same
      on-disk JSON shape for backward compatibility with existing
      installs' Keychain-stored credentials).
- [x] Replaced `SynologyClient.ConnectionSettings` with a new
      top-level `StoredCredentials` struct in `Settings.swift`. It's
      `Codable`, carries a computed `apiCredentials` convenience that
      produces the `SynologyAPI.Credentials` the actor expects, and
      stays `String`-typed on port for compatibility with existing
      stored data.
- [x] Deleted the `registerEvent(…)` no-op stub and its call sites in
      `DownloadsViewController`.
- [x] Removed the `synologyClient: SynologyClient?` global from
      `Shared.swift` and annotated the remaining UI-mutable globals
      (`synologyAPI`, `workStarted`, `mainMethod`, `mainViewController`,
      `currentViewController`) as `nonisolated(unsafe)` to silence
      complete-concurrency warnings about mutable global state. Phase
      4 replaces these with a proper `@Observable` app model; the
      annotation is honest about the current shape being unsafe rather
      than pretending it's been fixed.
- [x] Flipped `SWIFT_STRICT_CONCURRENCY` from `minimal` to `complete`.

### Phase 2 final polish (merged)

- [x] Cleared the final two strict-concurrency warnings surfaced by
      the `minimal → complete` flip:
      `nonisolated(unsafe) let userDefaults = UserDefaults.standard`
      in `Settings.swift` (matches the Shared.swift globals pattern),
      and `Webserver.swift`'s MainActor call wrapped in
      `Task { @MainActor in … }`. Project now builds warning-free
      under strict concurrency.
- [ ] Replace remaining `print(…)` sites with `os.Logger`. Remaining
      sites are in `Webserver.swift`; they go away with the webserver
      itself in Phase 3.

### Phase 2b — Credential store (merged)

- [x] Replaced KeychainAccess with a small wrapper around `SecItem*`
      in `SynologyDSManager/KeychainStore.swift`, using
      `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (item only
      readable while the device is unlocked; does not migrate to
      other Macs via iCloud Keychain or backups).
- [x] Rewrote `Settings.swift` on top of `KeychainStore`. Because
      both the old and new wrappers use `kSecClassGenericPassword`
      with the same service identifier, existing installs' stored
      credentials read back through the new code without needing a
      migration step.
- [x] Removed KeychainAccess from `Package.resolved` +
      `project.pbxproj`.
- [x] Stop persisting the SID — already done in Phase 2a-2a (the new
      `SynologyAPI` actor keeps the SID in memory only; the
      `StoredCredentials` type introduced in 2a-2d explicitly doesn't
      have an `sid` field).
- [x] Flipped `SWIFT_STRICT_CONCURRENCY` from `minimal` to `complete`
      — already done in Phase 2a-2d.

## Phase 3 — Safari extension & webserver bridge · **In progress** (3a + 3b-1 shipped)

Goal: eliminate the two remaining Phase-0 audit findings around the
extension ↔ main-app bridge:

1. The loopback HTTP server (`Webserver.swift`) accepts any local POST
   with no authentication; any process on the Mac can enqueue downloads.
2. The Safari App Extension format is deprecated (superseded by Safari
   Web Extensions since macOS 11 / Safari 14).

Both come out in this phase. Planned breakdown:

### Phase 3a — XPC bridge · **Shipped 2026-04-23**

Goal: a secure, code-signature-validated bridge from the Safari extension
territory into the main app. No new user-facing behaviour yet — just the
wiring that lets Phase 3b cut over.

- [x] Define an `@objc SynologyBridgeProtocol` with
      `enqueueDownload(url:reply:)` — `SynologyDSManager/Bridge/SynologyBridgeProtocol.swift`.
- [x] Add an XPC listener inside the main app that advertises the
      protocol via `NSXPCListener`. Serviced by `SynologyBridgeService`,
      which validates the URL (scheme allowlist + length cap), hops to
      the main actor to read the global `synologyAPI`, and forwards to
      `SynologyAPI.createTask(url:)`. Lifetime owned by `AppDelegate` via
      `SynologyBridgeListener`. Anonymous listener for now; Phase 3b
      swaps it for a Mach-service-registered one once the native
      messaging host target exists.
- [x] Validate the *client's* code signature on every connection via
      `auditToken` + `SecCodeCopyGuestWithAttributes` +
      `SecRequirementCreateWithString`. Expected peer is
      `com.skavans.synologyDSManager.bridge` signed by our Team ID.
      Implementation in `ClientAuthorization.swift`.
- [x] Unit tests: URL validation matrix, success / failure reply
      plumbing against a `URLProtocol`-stubbed `SynologyAPI`, and a
      shape check on `ClientAuthorization.currentTeamID()` —
      `SynologyDSManagerTests/SynologyBridgeTests.swift`. Cross-process
      authorisation denial needs a second signed binary, so it's
      deferred to Phase 3b integration testing.

### Phase 3b — Safari Web Extension (in progress; 3b-1 pushed)

Goal: replace the deprecated `SafariExtensionHandler` with a modern
Safari Web Extension that reaches the main app over XPC. Architecture
revision relative to the original plan: there is **no separate native-
messaging-host CLI**. Safari Web Extensions communicate with their
containing app via `browser.runtime.sendNativeMessage`, which arrives
at a `SafariWebExtensionHandler` subclass in the extension's own
`.appex` — that subclass is the XPC client, running in the extension's
sandboxed process.

#### Phase 3b-1 — source scaffolding · **Shipped 2026-04-23**

All new code, zero changes to existing compiled surface. Ships the
files the 3b-2 Xcode target will compile.

- [x] `WebExtension/SafariWebExtensionHandler.swift` — `NSExtensionRequestHandling`
      subclass that opens `NSXPCConnection(machServiceName:)` to the
      main app, dispatches one call per message, and replies with
      `{ok, error?}`. One-shot connections — no long-lived state in
      the sandboxed process.
- [x] `WebExtension/Resources/manifest.json` — MV3 manifest declaring
      the `contextMenus` + `nativeMessaging` permissions and the
      background service worker.
- [x] `WebExtension/Resources/background.js` — registers the right-
      click context-menu item (`contexts: ["link"]`) and forwards the
      chosen URL to the native handler. Content-script-free: Safari
      resolves the enclosing `<a>` automatically.
- [x] `WebExtension/Resources/_locales/en/messages.json` — i18n
      strings (extension name, description, menu item).
- [x] `WebExtension/Info.plist` + `SynologyDSManager_WebExtension.entitlements`
      — extension-point wiring and sandbox entitlements (with a
      `mach-lookup.global-name` exception for the bridge's Mach
      service, since sandboxed processes can't look up arbitrary
      global Mach names).
- [x] `SynologyDSManager/LaunchAgents/com.skavans.synologyDSManager.bridge.plist`
      — launchd plist that advertises the `com.skavans.synologyDSManager.bridge`
      Mach service name. On-demand (no `Program`/`ProgramArguments`) —
      the service is reachable whenever the main app is running but
      launchd never starts the app itself.
- [x] Updated Phase 3a code comments in `ClientAuthorization.swift`
      and `SynologyBridgeListener.swift` to reflect the finalized
      architecture (Web Extension as peer, not a separate CLI host).

#### Phase 3b-2 — Xcode target wiring (planned)

All the Xcode-side surgery to turn the scaffolding into compiled
products. See `WebExtension/README.md` for the step-by-step.

- [ ] Add a `SynologyDSManager WebExtension` target (Xcode's "Safari
      Extension App (Web Extension)" template). Bundle ID
      `com.skavans.synologyDSManager.bridge` (matches
      `ClientAuthorization.allowedPeerBundleIdentifier`). Point its
      sources at `WebExtension/` rather than the template's stubs.
- [ ] Share `SynologyDSManager/Bridge/SynologyBridgeProtocol.swift`
      with the Web Extension target (target-membership checkbox).
- [ ] Verify the main app's Copy Files build phase embeds the
      extension into `Contents/PlugIns/`.
- [ ] Add the LaunchAgent plist to the main target's Copy Files build
      phase with destination `Contents/Library/LaunchAgents/`.
- [ ] Register the agent on first launch with
      `SMAppService.agent(plistName:).register()` in `AppDelegate`;
      surface `.requiresApproval` as a modal pointing the user at
      System Settings → General → Login Items.
- [ ] Swap `NSXPCListener.anonymous()` → `NSXPCListener(machServiceName:)`
      in `SynologyBridgeListener`.
- [ ] Generate the three toolbar PNGs (`sips` one-liner in
      `WebExtension/Resources/icons/README.md`).
- [ ] The legacy `SynologyDSManager Extension` target stays enabled
      throughout 3b so existing users keep working; retired in 3c.

### Phase 3c — Delete the loopback bridge (planned)

Once 3b is shipping and the Web Extension can reach the main app via
XPC, retire the HTTP loopback path and its supporting infrastructure.

- [ ] Delete `SynologyDSManager/Webserver.swift`.
- [ ] Remove the `swifter` package from `Package.resolved` +
      `project.pbxproj`.
- [ ] Drop the `com.apple.security.network.server` entitlement from the
      main app's `SynologyDSManager.entitlements`.
- [ ] Remove the narrow `localhost` ATS exception from the Safari
      extension's `Info.plist`.
- [ ] Delete the legacy Safari App Extension target (`SynologyDSManager
      Extension`, `SafariExtensionHandler.swift`, `script.js`,
      `ToolbarItemIcon.pdf`, `Info.plist`, `entitlements`).
- [ ] Revisit the `synologydsmanager://download?downloadURL=…` URL
      scheme: either keep it as a general-purpose deep link for
      third-party apps with input validation and rate limiting, or drop
      it entirely (the Web Extension no longer needs a fallback path).

### Phase 3d — Chrome companion, if we keep it (planned)

Out-of-scope-until-asked. The original Chrome extension is referenced
in the README but isn't in this repo. If a user wants it revived, it'd
follow the same MV3 + native-messaging-host shape as 3b.

## Phase 4 — SwiftUI rewrite · **Planned**

Goal: storyboards out, SwiftUI in — screen by screen, behind
`NSHostingController` so we can ship as we go.

- [ ] Lift shared state into an `@Observable` app model; retire the global
      singletons in `Shared.swift`
- [ ] Port screens in this order: Settings → About → Add Download →
      BT Search → Choose Destination → Downloads list
- [ ] Replace the status item with `MenuBarExtra`
- [ ] Replace PNG toolbar icons with SF Symbols
- [ ] Delete `Main.storyboard` and all `.xib` files when the last screen
      has been ported
- [ ] Add localisation scaffolding (`String Catalog`), starting with English

## Phase 5 — Release engineering · **Planned**

Goal: signed, notarised, auto-updating releases cut by CI.

- [ ] Add Sparkle 2 with an EdDSA-signed appcast hosted on GitHub Pages or
      Releases
- [ ] Notarisation script + `xcrun stapler` step
- [ ] GitHub Action that on tag-push builds, signs, notarises, and attaches
      the DMG to a Release
- [ ] Cut a clean `v2.0.0` release

---

## Post-modernisation feature ideas (not started)

_Maintained here so they don't get lost. Promote to issues once Phase 4 is
shipping._

- Multi-NAS profiles with per-profile credentials
- App Intents / Shortcuts support ("Download this URL on the NAS…")
- Drag-and-drop of magnet links or `.torrent` files onto the status icon
- Richer search: pluggable providers, filter by min seeds / size
- Companion iOS app sharing the same Swift package for the API client
- Optional Touch Bar / trackpad gestures for pause/resume (if any user still
  has a Touch Bar in 2026)

---

## How to update this document

- Tick a checkbox the same commit that lands the change.
- When every checkbox in a phase is ticked, change the phase status to
  `Shipped · YYYY-MM-DD` and mention it in `CHANGELOG.md`.
- New work that doesn't fit an existing phase goes under **Post-modernisation
  feature ideas** with a one-line description, not a sub-heading.
