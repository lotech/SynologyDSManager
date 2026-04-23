# Modernisation plan

Living document. Tick boxes as tasks land. When all tasks in a phase are
complete, move the phase status from **In progress** / **Planned** to
**Shipped** with the date.

Last updated: 2026-04-23 (Phase 2 complete — Alamofire/SwiftyJSON dropped, strict concurrency on)

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

## Phase 2 — Networking & storage rewrite · **In progress**

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

### Phase 2a-2d follow-ups (planned, minor)

- [ ] Replace remaining `print(…)` sites with `os.Logger`. Most active
      `print` usage was in the now-deleted `SynologyClient.swift`, so
      this item is smaller than it was when planned. Remaining sites
      are in `Webserver.swift` and will go away with the webserver
      itself in Phase 3.

### Phase 2b — Credential store & strict concurrency (planned)

- [ ] Replace KeychainAccess with a small wrapper around `SecItem*`,
      `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`; stop persisting the SID
- [ ] Remove KeychainAccess from `Package.resolved` + `project.pbxproj`
- [ ] Flip `SWIFT_STRICT_CONCURRENCY` from `minimal` to `complete`

## Phase 3 — Safari extension & webserver bridge · **Planned**

Goal: no unauthenticated local listener; no deprecated Safari App
Extension.

- [ ] Add a new **Safari Web Extension** target (MV3 manifest + JS service
      worker + native messaging host)
- [ ] Implement `NSXPCConnection` between the native messaging host and the
      main app; define a small `@objc` protocol (`enqueueDownload(URL:)`)
- [ ] Delete `Webserver.swift` and drop the `Swifter` package
- [ ] Delete the `synologydsmanager://download` URL-scheme fallback in the
      Safari extension (or lock it down to a launch-agent-signed token)
- [ ] Remove the `localhost` ATS exception and `network.server` entitlement
      once the webserver is gone
- [ ] Update the Chrome extension (if kept) to use the same MV3 +
      native-messaging shape

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
