# Changelog

All notable changes to SynologyDSManager are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from `v2.0.0` onward.

Entries are grouped under **Added / Changed / Deprecated / Removed / Fixed /
Security**. Add new user-visible changes under `## [Unreleased]` in the same
commit that makes them.

## [Unreleased]

### Added
- **Phase 3b-2b — Web Extension Xcode target.** The missing half of
  Phase 3b: the `SynologyDSManager WebExtension` target itself, which
  compiles the source tree that shipped in 3b-1 and embeds the
  resulting `.appex` into the main app's `Contents/PlugIns/` next to
  the legacy extension. With 3b-2a's Mach service listener already
  live, this is the point at which the end-to-end bridge path becomes
  functional — a right-click on a link in Safari reaches
  `SafariWebExtensionHandler`, opens an `NSXPCConnection` to
  `com.skavans.synologyDSManager.bridge`, and ends up at
  `SynologyAPI.createTask(url:)` in the main app. Credentials never
  cross the XPC boundary; the extension only ever sees URLs. The
  legacy `SynologyDSManager Extension` target stays enabled in
  parallel so existing users aren't broken while the new path gets
  real-world exercise; Phase 3c retires it and `Webserver.swift`.
  - Target bundle ID `com.skavans.synologyDSManager.bridge` — matches
    `ClientAuthorization.allowedPeerBundleIdentifier` so the main app
    accepts the XPC peer.
  - `SynologyBridgeProtocol.swift` is target-membership-shared
    between the main app and the Web Extension; both sides compile
    the same `@objc` protocol, and `NSXPCConnection` matches on
    Obj-C runtime name so the wire format stays in sync.
  - Three toolbar PNGs (48 / 96 / 128) rasterised from the legacy
    extension's `ToolbarItemIcon.pdf` and wired into the target's
    Copy Bundle Resources phase.

### Fixed
- **Web Extension target's signing diverged from the main app.** Xcode's
  "Safari Web Extension" wizard had hardcoded a handful of settings at
  target level that should inherit from the project's `Signing.xcconfig`
  cascade — specifically `CODE_SIGN_IDENTITY[sdk=macosx*] = "Apple
  Development"` and `CODE_SIGN_STYLE = Automatic`. Those overrides
  short-circuited the per-configuration logic the xcconfig uses to
  split Debug (Automatic + Apple Development) from Release (Manual +
  Developer ID Application) and produced *"Embedded binary is not
  signed with the same certificate as the parent app"* at embed time.
  Stripped them so the WebExtension target picks up identity and style
  exactly like the main app does. Also normalised `CURRENT_PROJECT_VERSION`
  and `MARKETING_VERSION` to match the parent (`12` / `2.0.0`), removed
  the wizard's `GENERATE_INFOPLIST_FILE = YES` so our hand-authored
  `WebExtension/Info.plist` is used verbatim (the `NSExtension` dict is
  load-bearing and a merged plist can lose it), dropped two dead
  `INFOPLIST_KEY_*` entries, and dropped the target-level
  `MACOSX_DEPLOYMENT_TARGET = 13.5` override so the target inherits the
  project's `13.0` floor.
- **Web Extension handler tripped Swift 6 sendability checks.** The
  trailing closure passed to `proxy.enqueueDownload` is `@Sendable`
  (enforced by the protocol since the earlier Bridge-side fix), but
  captured `self`, the `NSExtensionContext`, and the `NSXPCConnection`
  — none of which are `Sendable`. Rewrote the handler to bridge the
  XPC reply through a `CheckedContinuation`, so the `@Sendable`
  boundary only carries `(Bool, String?)` (both `Sendable`); the
  non-`Sendable` values travel into the outer `Task` in a tiny
  `@unchecked Sendable` wrapper (`UncheckedBox`) whose values outlive
  exactly one round-trip and aren't touched concurrently.
- **Bridge LaunchAgent rejected by launchd at first launch.** The
  Phase 3b-2a plist omitted `Program`/`ProgramArguments`/`BundleProgram`
  on the theory that a pure-check-in Mach service agent doesn't need
  one. launchd disagreed and rejected the plist with "Missing
  program" + "plist content is invalid", which surfaced as
  `SMAppService.register` failing with status 3. Added a
  `BundleProgram = Contents/MacOS/SynologyDSManager` key —
  SMAppService resolves this relative to the app bundle, so the
  agent follows the app to whichever directory it's installed in.
  Side effect: if the app is closed when a Safari extension click
  reaches the Mach service, launchd will now spawn it. That's the
  better UX (right-click → download → app launches to enqueue) vs.
  the legacy webserver path which silently failed when the app was
  closed.

### Added
- **Phase 3b-2a — Main-app-side Mach service wiring.** The main app
  now advertises a named Mach service for the bridge and registers
  the LaunchAgent that backs it. No behaviour change for existing
  users yet — nothing connects to the listener until Phase 3b-2b
  adds the Web Extension target. Safe to ship alone because a named
  `NSXPCListener` without launchd routes simply sits idle.
  - `SynologyBridgeListener` swapped from `NSXPCListener.anonymous()`
    to `NSXPCListener(machServiceName: "com.skavans.synologyDSManager.bridge")`.
    The name is exposed as `SynologyBridgeListener.machServiceName`
    so the 3b-2b Web Extension handler reads from a single source
    of truth.
  - `AppDelegate.applicationWillFinishLaunching` now calls
    `SMAppService.agent(plistName:).register()`. The call is
    idempotent and diagnostic-only on failure: if the plist isn't
    bundled yet (pre-build-phase change) or the user hasn't yet
    approved the login item in System Settings, the app still
    launches cleanly — only the bridge stays dark.
  - `project.pbxproj` gains an "Embed LaunchAgents" Copy Files
    build phase on the main target. It bundles
    `SynologyDSManager/LaunchAgents/com.skavans.synologyDSManager.bridge.plist`
    into the app at `Contents/Library/LaunchAgents/`, which is
    where `SMAppService.agent(plistName:)` looks for it.

- **Phase 3b-1 — Safari Web Extension source scaffolding.** Source
  tree for the replacement Safari extension, in the new
  `WebExtension/` directory. No compiled-code changes yet — this
  ships only the files that Phase 3b-2 will bring into an Xcode
  target. The existing legacy `SynologyDSManager Extension` keeps
  working and stays enabled throughout Phase 3b.
  - `SafariWebExtensionHandler.swift` — the extension's
    `NSExtensionPrincipalClass`, running in its own sandboxed
    process. On each message from JS it opens a one-shot
    `NSXPCConnection(machServiceName:)` to the main app, forwards
    a single `enqueueDownload(url:)`, and replies with a small
    `{ ok, error? }` payload. Credentials never cross this
    boundary — the handler only sees URLs to enqueue.
  - `Resources/manifest.json` — MV3 manifest declaring the
    `contextMenus` + `nativeMessaging` permissions, a background
    service worker, and Safari 16.4 as the minimum version (first
    Safari release with complete MV3 support).
  - `Resources/background.js` — service worker that registers a
    right-click context-menu on links (`contexts: ["link"]`) and
    dispatches the chosen URL to the native handler. No content
    script needed — Safari resolves the enclosing `<a>` for us,
    replacing the old extension's walk-up-from-click-target
    JavaScript.
  - `Resources/_locales/en/messages.json` — i18n strings for the
    extension name, description, and the context-menu item.
  - `Info.plist` + `SynologyDSManager_WebExtension.entitlements` —
    declares the `com.apple.Safari.web-extension` extension point
    and sandbox settings. Includes an explicit
    `mach-lookup.global-name` exception for the bridge's Mach
    service, because sandboxed processes can't look up arbitrary
    global Mach names.
  - `SynologyDSManager/LaunchAgents/com.skavans.synologyDSManager.bridge.plist`
    — launchd plist that will be bundled inside the main app's
    `Contents/Library/LaunchAgents/`. On-demand by design (no
    `Program`/`ProgramArguments`): the Mach service name is
    advertised to launchd whenever the main app is running, and
    launchd never starts the app itself. Registered
    programmatically via `SMAppService.agent(plistName:)` in 3b-2.
  - `WebExtension/README.md` documents the step-by-step Xcode work
    remaining for Phase 3b-2 (new target creation, target
    membership sharing for the bridge protocol, Copy Files phases
    for the `.appex` and the LaunchAgent plist, the
    `SMAppService.register()` call, and the flip from
    `NSXPCListener.anonymous()` to `NSXPCListener(machServiceName:)`).

- **Phase 3a — XPC bridge scaffolding.** Introduced a new `Bridge/`
  module that sets up the wire and trust boundary the future Safari
  Web Extension will talk across. No user-visible behaviour yet; the
  existing loopback webserver still handles Safari-extension enqueue
  requests until Phase 3c retires it.
  - `SynologyBridgeProtocol` — a deliberately small `@objc` protocol
    with one method (`enqueueDownload(url:reply:)`), so the wire
    surface between the app and the extension stays easy to audit.
  - `SynologyBridgeService` — validates incoming URLs (scheme
    allowlist + length cap to blunt buffer-stuffing tricks), hops to
    the main actor to read the shared `SynologyAPI`, and forwards to
    `createTask(url:)`. Errors are surfaced as an optional reply
    message rather than leaking stack frames across the XPC boundary.
  - `ClientAuthorization` — validates every incoming XPC peer's
    code signature via `auditToken` + `SecCodeCopyGuestWithAttributes`
    + a `SecRequirementCreateWithString` designated requirement. Only
    our own native messaging host (signed by our Team ID) can ever
    reach the exported interface; arbitrary local processes are
    refused before any protocol method runs.
  - `SynologyBridgeListener` — an `NSXPCListener.anonymous()` started
    at app launch from `AppDelegate`. Anonymous for now so nothing
    external can reach it; Phase 3b swaps it for
    `NSXPCListener(machServiceName:)` once the native messaging host
    target + LaunchAgent plist are in the bundle.
  - Unit tests covering URL validation (empty, whitespace, unsupported
    scheme, schemeless input, absurdly long input, supported schemes),
    success / failure reply plumbing against a `URLProtocol`-stubbed
    `SynologyAPI`, the not-signed-in branch, and a shape check on
    `ClientAuthorization.currentTeamID()`. Cross-process peer-denial
    needs a second signed binary, so it's deferred to Phase 3b
    integration testing.

### Removed
- **Phase 2b — dropped the KeychainAccess third-party package.**
  Replaced with a new `KeychainStore.swift` — a thin Swift wrapper
  around Apple's `SecItem*` primitives. Uses
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` so credentials are
  only readable while the device is unlocked AND don't migrate across
  Macs via iCloud Keychain / Time Machine restores.
  Existing installs' stored credentials keep working transparently:
  both the old and new wrappers use `kSecClassGenericPassword` with
  the same service identifier, so the same Keychain items are visible
  through either API. No migration step is needed.
- **Phase 2a-2d cleanup.** End of the Phase 2a migration:
  - Deleted `SynologyClient.swift` — the legacy Alamofire-backed DSM
    client (~300 lines). Every caller migrated over the course of 2a-2a
    through 2a-2c.
  - Removed **Alamofire** and **SwiftyJSON** from the project's Swift
    Package Manager dependencies (both targets) and from
    `Package.resolved`. First-clean-build time should drop noticeably
    — Alamofire alone is ~70k LoC.
  - Migrated `SafariExtensionHandler.swift` off Alamofire onto
    `URLSession`. Same fallback behaviour: POST to the loopback
    webserver, fall back to the custom URL scheme. Whole extension
    gets replaced in Phase 3.
  - Replaced `SynologyClient.ConnectionSettings` with a new top-level
    `StoredCredentials` struct in `Settings.swift`. Codable, port
    stays `String`-typed for backward compatibility with existing
    installs, with a computed `apiCredentials` convenience that
    produces the typed `SynologyAPI.Credentials` the actor expects.
    Unknown keys (like the old `sid` field) decode cleanly — no
    explicit migration needed.
  - Deleted the `registerEvent(…)` no-op stub and its call sites in
    `DownloadsViewController`.
  - Removed the unused `synologyClient: SynologyClient?` global from
    `Shared.swift`.

### Changed
- **Phase 3a code-comment clarifications.** Tightened two comments
  in `ClientAuthorization.swift` and `SynologyBridgeListener.swift`
  that described the Phase 3b peer as a "native messaging host
  binary". It's actually the Safari Web Extension's
  `SafariWebExtensionHandler` subclass, running in an `.appex`
  bundled at `Contents/PlugIns/`. Behaviour unchanged; the comments
  now match the finalized architecture.
- **Strict concurrency flipped from `minimal` to `complete`.** Swift's
  full concurrency checking is now on. Remaining globals in
  `Shared.swift` (`synologyAPI`, `workStarted`, `mainMethod`,
  `mainViewController`, `currentViewController`) are annotated as
  `nonisolated(unsafe)` — an honest acknowledgement that they're
  thread-unsafe mutable state the current architecture treats as
  main-thread-only by convention. Phase 4 (SwiftUI + Observation)
  replaces them with a proper `@Observable` app model.
- **`Settings.swift` rewritten on `JSONEncoder` / `JSONDecoder`** —
  the Keychain blob format is byte-compatible with the old SwiftyJSON
  output, so existing installs don't need a migration. A legacy path
  for installs where credentials still live in `UserDefaults` (from
  pre-Keychain releases) migrates them into the Keychain on first read.
- **Add / Search / Destination migration (Phase 2a-2c)** — the last
  three legacy-client-backed screens now run on `SynologyAPI`:
  - `AddDownloadViewController` enqueues downloads via
    `createTask(url:)` and `createTask(torrentFile:)` in a detached
    Task so the sheet can close immediately. Errors log via
    `AppLogger.network`; the downloads list refresh surfaces what
    actually landed.
  - `BTSearchController` is now built on the actor's
    `searchTorrents` (cancellable polling inside the actor, not a
    nested `Timer.scheduledTimer`). Typed `[BTSearchResult]` replaces
    `JSON?`; checkbox state is tracked separately in a `Set<String>`
    so the DTO stays pure. Cancels any in-flight search when the
    window closes.
  - `ChooseDestViewController` uses `listDirectories`. The `RemoteDir`
    tree-node class moved from `SynologyClient.swift` into the view
    controller (it's the right abstraction for `NSOutlineView` but
    nothing else needs it).
  - `DestinationView` dropped `import SwiftyJSON` — the
    `downloadDestinations` UserDefaults blob is now encoded/decoded
    via `JSONEncoder`/`JSONDecoder` in a format backward-compatible
    with the old SwiftyJSON output (existing installs keep working).
  - `downloadByURLFromExtension` in `DownloadsViewController` uses
    `createTask(url:)`.
- **Removed the transitional legacy-client authentication** —
  `DownloadsViewController.doWork` no longer creates or authenticates
  a `SynologyClient`; `SettingsViewController`'s credentials-change
  branch also stopped touching the legacy client. Nothing in the app
  references `synologyClient` anymore except its declaration in
  `Shared.swift`; the declaration + `SynologyClient.swift` itself
  come out in Phase 2a-2d cleanup.
- **New regression-guard tests** for `createTask(url:)` (payload
  shape, nil-destination omission), `searchTorrents` (poll-until-done
  behaviour, request order), and `listDirectories` (typed decoding,
  null-files resilience).
- **Downloads migration (Phase 2a-2b)** — the main download list, the
  pause-all / resume-all / clear-finished toolbar actions, the per-row
  pause/resume/delete buttons, and the 3-second refresh loop now all run
  on `SynologyAPI` (URLSession + async/await + typed `[DSMTask]`)
  instead of the legacy Alamofire-backed `SynologyClient`. SwiftyJSON is
  no longer imported in `DownloadsViewController.swift`. The polling
  loop is now an `async Task` (`refreshTask`) that honours
  `Task.isCancelled` and auto-cancels on repeat `doWork` invocations,
  replacing the old `Timer.scheduledTimer` which (combined with a
  latent `workStarted` bug) could stack multiple concurrent timers
  after credential changes.
- `SettingsViewController`'s "already running, credentials changed"
  branch now also calls `SynologyAPI.updateCredentials` + `authenticate`
  so the downloads refresh keeps working after the user switches NAS
  or rotates passwords (it was previously only re-authing the legacy
  client).
- `doWork` now sets `workStarted = true` at the end. The flag was
  declared in the original codebase but never written, so every Test
  Connection re-entered `doWork`, stacking a new legacy client and a
  new refresh timer each time. Now the Settings else-branch fires on
  the second and subsequent Test Connections, as originally intended.

### Fixed
- **Final two strict-concurrency warnings cleared**, completing the
  zero-warning goal after `SWIFT_STRICT_CONCURRENCY = complete` landed
  in Phase 2a-2d:
  - `Settings.swift`: the module-level `userDefaults` global was flagged
    because `UserDefaults` isn't formally `Sendable`. Annotated with
    `nonisolated(unsafe)` (same pattern as `Shared.swift`'s globals)
    and switched `UserDefaults()` to `.standard` which is the idiomatic
    spelling for the shared instance.
  - `Webserver.swift`: Swifter's HTTP handler runs on a background
    queue but called `DownloadsViewController.downloadByURLFromExtension`
    which is `@MainActor`-isolated. Wrapped the call in
    `Task { @MainActor in … }`, passing the URL String (a `Sendable`
    value) across. Same runtime behaviour (still lands on main), now
    provably correct to the compiler. This fix is a stop-gap — the
    whole file is deleted in Phase 3 when the unauthenticated loopback
    bridge is replaced with a Safari Web Extension + native messaging
    host bridge.
- **Phase 2a-2b regression: empty task list after migrated Downloads screen
  connected to DSM**. `SynologyAPI` was authenticating fine (and storing
  a session cookie), but DSM returned a successful-but-empty task list
  because URLSession's cookie jar was not sending the `id=<sid>` cookie
  in a form DSM treats as authoritative. Fix: pass `_sid=<sid>` in the
  POST body of every authenticated request via an `authenticated: Bool`
  parameter on `SynologyAPI.post()` (defaults to `true`; `authenticate()`
  explicitly passes `false`). The cookie is still installed as a
  secondary channel. This also keeps the SID out of URL query strings,
  which was the original motivation for not reusing the old Alamofire
  path — `_sid` in the body doesn't leak into referer headers, proxy
  logs, or crash reports the way a URL parameter would.
- **Phase 2a-2a regression: crash on first refresh after Test Connection**
  — `SynologyClient.getDownloads` and siblings force-unwrap
  `settings.sid!`. Before Phase 2a-2a, `SettingsViewController`
  authenticated via the legacy client, which populated the SID on the
  `ConnectionSettings` struct passed to `DownloadsViewController.doWork`.
  Phase 2a-2a moved auth to `SynologyAPI`, which uses a cookie jar
  internally rather than writing to the legacy struct, so the legacy
  client arrived in `doWork` SID-less and crashed on the first timer
  tick. Fix: `doWork` now calls `synologyClient.authenticate` itself
  and only starts the refresh loop on success; the `SettingsViewController`
  "already running, credentials changed" branch does the same. Both
  code paths go away in Phase 2a-2b when the refresh loop moves to
  `SynologyAPI`.

### Added
- **Test target wired into the Xcode project** — `SynologyDSManagerTests`
  is now a full macOS unit-test bundle hosted by the main app, so
  `⌘U` / `xcodebuild test` just works after a fresh clone. Notable
  configuration:
  - macOS-only (`SDKROOT = macosx`, `SUPPORTED_PLATFORMS = macosx`,
    `SUPPORTS_MACCATALYST = NO`). Xcode 16's "New Target" UI defaults
    to iOS/Catalyst even with macOS selected, which silently breaks
    `@testable import` because the bundle builds for
    `arm64-apple-ios-macabi` while the app is pure macOS. Explicit
    platform pinning prevents that.
  - `MACOSX_DEPLOYMENT_TARGET = 14.0` on the test bundle (the app
    stays at 13.0). Xcode 16's XCTest.framework is built against
    macOS 14.0+.
  - `TEST_HOST` / `BUNDLE_LOADER` pointing at the app binary,
    `PBXTargetDependency` on the app for build order.
  - No hardcoded `DEVELOPMENT_TEAM` — signing inherits from the
    `Signing.xcconfig` cascade. (Xcode injected the Team ID into
    five places during target creation; all stripped.)
- **CI now runs `xcodebuild test` on every PR** — new `test` job
  added to `.github/workflows/ci.yml` alongside the existing build
  and lint jobs. Any regression that breaks `SynologyAPITests` fails
  CI before it can land.
- **Unit test scaffolding (Phase 2a-2d — test target)** — a
  `SynologyDSManagerTests/` directory with:
  - `URLProtocolStub.swift`: `URLProtocol` subclass that intercepts
    `URLSession` requests during tests, serves canned responses, and
    captures request bodies so tests can assert on what was actually
    sent. Supports queued multi-step response sequences for flows like
    authenticate → listTasks → pause, and form-field parsing helpers.
  - `SynologyAPITests.swift`: XCTest suite covering authenticate
    success/failure, listTasks typed decoding, URL shape, pause /
    resume / delete payloads, HTTP / decoding / transport error paths,
    updateCredentials session invalidation, logout, and
    SynologyErrorCode mapping. Two explicit regression-guard tests for
    the 2a-2b bugs: one asserts `_sid` is always in the POST body for
    authenticated requests; another asserts SID never appears in URL
    query strings — either would have failed immediately against the
    pre-fix implementation.
- `SynologyAPI.init` now accepts an optional `URLSessionConfiguration`
  (defaults to `nil`) so tests can register `URLProtocolStub.self` as
  a `protocolClass` without touching production construction.
- Test-running instructions and one-time test-target wiring steps
  added to `CLAUDE.md`. Adding the test *target* itself is a File →
  New → Target → Unit Testing Bundle operation in Xcode; the
  resulting pbxproj change should land as a follow-up PR after this
  one merges.
- **Settings migration & SPKI approval UI (Phase 2a-2a)** — the
  authentication flow in `SettingsViewController.testConnectionButtonClicked`
  now uses the new `SynologyAPI` (URLSession + async/await) rather than
  the legacy Alamofire-based `SynologyClient`. First-use of a self-signed
  Synology certificate now shows an `NSAlert` with the SHA-256 SPKI
  fingerprint and asks the user to explicitly trust it — the old
  silent-accept-anything `DisabledEvaluator` bypass is gone. Approved
  pins are persisted per-host and reused silently on subsequent
  connections; mismatches against an existing pin are refused outright.
  `synologyAPI` is now available as a parallel global alongside the
  legacy `synologyClient`; both are initialised from the same settings
  in `DownloadsViewController.doWork`. Remaining view controllers are
  still on the legacy client — they migrate in Phase 2a-2b / c.
- **Networking foundation (Phase 2a-1)** — a new `SynologyDSManager/Network/`
  module landed alongside the existing Alamofire-based client, to be swapped
  in wholesale during Phase 2a-2:
  - `SynologyAPI.swift`: actor-isolated DSM API client built on
    `URLSession` + `async/await`. Supports auth, task list / pause / resume /
    delete, URL and torrent-file creates, BT search (cancellable polling),
    directory listing, and logout. Session ID is carried as a cookie, never
    as a `_sid=` query parameter.
  - `SynologyAPIModels.swift`: typed `Codable`/`Sendable` DTOs for every
    DSM response the app consumes, plus a `DSMFormBody` helper for
    `application/x-www-form-urlencoded` POST bodies.
  - `SynologyTrustEvaluator.swift`: `URLSessionDelegate` implementing
    SPKI-SHA256 pinning (RFC 7469). On first contact with a self-signed
    cert, the observed fingerprint is passed to `pendingApproval` so the UI
    can prompt the user. Approved pins are persisted per-host in
    `UserDefaults`. Mismatches against an existing pin are refused.
  - `SynologyError.swift`: typed `LocalizedError` enum covering transport,
    HTTP, decoder, DSM API, authentication, trust, and torrent-read
    failures, with a `SynologyErrorCode.message(for:)` mapping for DSM's
    numeric error codes.
  - `AppLogger.swift`: shared `os.Logger` categories (`network`, `auth`,
    `security`, `keychain`) with a documented contract that credentials,
    OTPs, and session IDs must never appear in log messages.
- `SECURITY.md` — private disclosure policy pointing reporters at GitHub
  Security Advisories, with a list of high-signal areas (credential
  handling, TLS, Keychain, the local HTTP bridge, URL-scheme handling,
  the Safari/Chrome extensions) and clear response-time expectations for
  this hobby-maintained fork.
- `CLAUDE.md` — orientation file for future AI-assisted work on the repo,
  now including a *Public-repo best practices* section (secrets handling,
  log redaction, release/signing rules) and a *Code signing* section.
- `MODERNIZATION_PLAN.md` — phased roadmap with a per-phase task checklist
  that is kept up to date as work lands.
- `CHANGELOG.md` (this file).
- `deploy.sh` — interactive single-key maintainer menu:
  - `p` pull `main` from origin into local `main`
  - `o` open in Xcode
  - `s` configure signing (writes `Signing.local.xcconfig`)
  - `i` build Release and install to `/Applications`
  - `d` build Release and produce a signed (and, if credentials are
        configured, notarised) DMG
- `Signing.xcconfig` + `Signing.local.xcconfig.template` — xcconfig cascade
  that keeps Apple Developer Team IDs out of the public repo. The local
  override is gitignored and is wired as `baseConfigurationReference` on
  both project-level build configurations, so Xcode GUI builds and
  `xcodebuild` both pick up the Team ID automatically.
- Gitignore entries for `Signing.local.xcconfig`, `.notary-profile-name`,
  `build/`, `dist/`, and `.DS_Store`.
- GitHub Actions CI workflow (`build`, `SwiftLint`, `SwiftFormat --lint`).
- `CODEOWNERS`, PR template, and bug / feature / security issue templates.
- `.swiftlint.yml`, `.swiftformat`, `.swift-version` — initial lint/format
  baseline. CI enforcement is non-blocking until the repo is reformatted.
- One-time `UNUserNotificationCenter` authorisation request on launch so
  download-finished / download-started alerts still appear under the
  non-deprecated notification API.

### Changed
- `deploy.sh`: the `p` (pull main) action now handles uncommitted local
  changes cleanly. Previously the underlying `git pull --ff-only` would
  abort with *"Your local changes to the following files would be
  overwritten by merge"* and leave the user to work out the stash-pull-pop
  dance themselves. The script now detects a dirty working tree up-front
  and offers three options: **s** stash + pull + auto-reapply,
  **d** discard (with a secondary y/N confirmation) + pull, or
  **c** cancel. Stash-pop conflicts print a step-by-step recovery guide
  rather than failing silently.
- Aligned `CURRENT_PROJECT_VERSION` (CFBundleVersion) across both targets to
  `12`. The Safari extension was at `6` while the main app was at `12`,
  which Xcode flagged as a warning on build. Apple requires an app
  extension's bundle version to match its containing parent app's.
- Minimum supported macOS raised from 10.13 (High Sierra) to 13 (Ventura).
- Xcode project format bumped: `objectVersion` 52 → 56, `compatibilityVersion`
  Xcode 9.3 → Xcode 14.0, `LastUpgradeCheck` / `LastSwiftUpdateCheck` →
  1520 (Xcode 15.2). `BuildIndependentTargetsInParallel` enabled.
- Replaced `@NSApplicationMain` with `@main` (the old attribute is deprecated
  in Swift 5.3+).
- Replaced `NSUserNotification` + `NSUserNotificationCenter` (deprecated
  since macOS 10.14) with `UNUserNotificationCenter` + `UNNotificationRequest`.
- Replaced `NSOpenPanel.allowedFileTypes` (deprecated since macOS 12) with
  `allowedContentTypes: [UTType]`.
- Replaced `protocol LoadableView: class` with the non-deprecated
  `: AnyObject`.
- Enabled `SWIFT_STRICT_CONCURRENCY = minimal` on both configurations, a
  stepping-stone toward `complete`.
- `README.md` rewritten for the maintained-fork state, linking the new
  `CLAUDE.md` / `MODERNIZATION_PLAN.md` / `CHANGELOG.md`.
- `README.md`: expanded the project's pre-fork history paragraph and added a
  dedicated *Acknowledgements* section crediting [@skavans](https://github.com/skavans)
  as the original author of the app, Safari extension, and surrounding code.
  Split the *Licence* section to call out both the original copyright (2020–2023)
  and the modernisation contributors' copyright (2024–present) explicitly.
- Marketing version bumped to `2.0.0` to signal the modernisation break;
  CFBundleShortVersionString will stay on `2.0.0-dev` until a Phase 5 release
  is cut.

### Removed
- Stale `DEVELOPMENT_TEAM = GVS9699BGK` (the previous maintainer's Apple
  team) from both targets' build configurations. The current developer's
  Team ID is now supplied via the gitignored `Signing.local.xcconfig`.
- Target-level hard-coded `CODE_SIGN_IDENTITY = "Apple Development"`, so the
  xcconfig's conditional identity (Apple Development for Debug, Developer ID
  Application for Release) wins.
- Dead `FRAMEWORK_SEARCH_PATHS` entries referencing a non-existent
  `Sparkle Updater` directory.
- Unused `StoreKit.framework` reference (leftover from the paid-app IAP
  flow, which was never shipped in the open-source version).
- `xcuserdata/` directories are no longer tracked (already ignored by
  `.gitignore`; had been committed before the ignore rule landed).

### Security
- Removed the blanket `NSAllowsArbitraryLoads = true` from the main app's
  `Info.plist`. The app now honours App Transport Security defaults (HTTPS,
  TLS 1.2+, forward secrecy). The narrower `localhost` exception in the
  Safari extension is kept for now and will be removed together with the
  loopback HTTP bridge in Phase 3.
- Pinned `actions/checkout` in the CI workflow to a full commit SHA
  (`34e114876b0b11c390a56381ad16ebd13914f8d5`, tagged `v4.3.1`) instead of
  the mutable `@v4` tag, so an upstream repo compromise can't silently
  change what runs in our CI. Inline comment in `.github/workflows/ci.yml`
  documents how to bump the pin for future releases.

### Notes for users upgrading
- If your NAS is reachable only via HTTP or weak TLS, connections will now
  fail. Proper self-signed-cert / SPKI-pinning handling lands in Phase 2;
  until then, prefer an HTTPS DSM setup with a TLS 1.2+ cert.
- You will need to re-enter your Apple Developer team on first build.

---

## Historical

Everything before this fork was maintained at
[`skavans/SynologyDSManager`](https://github.com/skavans/SynologyDSManager)
and shipped up to `v1.4.2` (main app) / `v1.2.1` (Safari extension).
No further entries are planned for versions before the 2026 fork.
