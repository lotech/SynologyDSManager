# Changelog

All notable changes to SynologyDSManager are documented here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the
project aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
from `v2.0.0` onward.

Entries are grouped under **Added / Changed / Deprecated / Removed / Fixed /
Security**. Add new user-visible changes under `## [Unreleased]` in the same
commit that makes them.

## [Unreleased]

### Changed
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
