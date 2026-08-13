# SynologyDSManager

> ## ⚠️ This project is no longer maintained
>
> **Status: unmaintained as of August 2026.**
>
> I've replaced my Synology NAS with an Unraid server, so I no longer have any
> Synology hardware to develop or test against. Without a NAS to point it at I
> can't verify a single change, so rather than let the project drift into
> untested commits I'm stopping here.
>
> **The app still works.** Version 2.2.1 is functional against DSM 6.2+ and
> there are no known broken features. Nothing is being taken away — the code,
> the history, and the releases stay up.
>
> What "unmaintained" means in practice:
>
> - **No new features, bug fixes, or security patches** will ship, including
>   for the known issues listed in [`SECURITY.md`](./SECURITY.md).
> - **Issues and pull requests are not being monitored.** Please don't expect a
>   reply.
> - **No security reports, please.** See [`SECURITY.md`](./SECURITY.md) — there
>   is no one on the other end to triage or fix them.
> - **Nothing will be verified against future macOS or DSM releases.** Expect it
>   to break eventually, most likely when Apple retires an API it depends on or
>   Synology changes the Download Station API.
>
> **Forks are welcome and encouraged.** The licence is GPL-3.0 (copyleft — a
> private fork carries no publishing obligation, but if you distribute a build
> you must offer its source too) and the code is in good shape: Phase 2 rewrote
> all networking and storage onto Apple's own SDKs, and it ships with 33 unit
> tests. If you want to carry it forward, fork it; you don't need to ask. See
> [`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md) for what was left undone.
>
> If you are *using* the app, please read the
> [known unfixed security issues](./SECURITY.md#known-unfixed-issues) before
> deciding to keep it installed.

A native macOS app for managing a Synology DownloadStation remotely. It also
bundles a legacy Safari App Extension, which ships and can be enabled in Safari
even though the app's own UI toggle for it is disabled — see the features list
and [known unfixed issue 3](./SECURITY.md#known-unfixed-issues). Its intended
replacement, a Safari Web Extension, was partly built and never finished.

This was a maintained fork of the excellent original project by
[**Anton (@skavans)**](https://github.com/skavans), which lived at
[**skavans/SynologyDSManager**](https://github.com/skavans/SynologyDSManager) from
2020 through 2023. Anton built the whole app — the DSM API client, the Cocoa
UI, the Safari extension, the BT search flow, keychain-backed credentials,
2FA support, and everything else you see on screen. The app was originally
a paid product sold through Paddle, and when that payment channel stopped
working for sellers in Russia in 2022, Anton open-sourced the project rather
than letting it fade away. That generosity is the only reason this fork
exists, and the only reason the code has a second life.

Goals of this fork were:

- modernise the codebase (SwiftUI, Swift concurrency, current macOS APIs) —
  **done**
- run a full security audit and fix the outstanding issues — **mostly done**;
  see [`SECURITY.md`](./SECURITY.md) for what was left unfixed
- add new features after the modernisation baseline is in place — **partly
  done**, and stopped here

See [`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md) for the phased roadmap
(now closed) and [`CHANGELOG.md`](./CHANGELOG.md) for the full list of changes.

## Features

- Browse downloads in a native, sortable table (Name, Progress, Size, Status,
  Speed) with single/multi-selection and a right-click menu to pause, resume,
  copy the magnet link, or remove tasks
- Add new tasks from `.torrent` files, magnet links, or direct URLs — in bulk,
  with per-item failure reporting if the NAS rejects something
- Pick any shared folder on the NAS as the download destination
- Search BT trackers directly from the app and enqueue results in one click
- Menu-bar status item with live bandwidth readout, plus an optional Dock-icon
  badge showing the number of finished downloads
- 2-step verification (TOTP) supported
- Safari extension ("Download with Synology DS Manager" from the page context
  menu) — the *replacement* Web Extension was never finished, blocked by a
  Safari-side bug (see `CLAUDE.md`), so the feature stays disabled in the app's
  UI and won't be completed here. **The older legacy Safari App Extension does
  still ship**, embedded in the app bundle, and can be switched on in Safari →
  Settings → Extensions independently of that UI toggle. If you enable it, note
  that it writes complete download URLs to the unified log — see
  [known unfixed issue 3](./SECURITY.md#known-unfixed-issues).

## Requirements

- macOS 14 (Sonoma) or newer
- Xcode 15 or newer to build
- A reachable Synology DSM 6.2+ installation with Download Station installed

Last verified against macOS 26.x and DSM 7.x in mid-2026. Nothing beyond that
has been tested, and nothing will be — see the status notice at the top.

## Building

```sh
git clone https://github.com/lotech/synologydsmanager.git
cd synologydsmanager
./deploy.sh        # interactive helper — see below
```

`deploy.sh` is a single-key menu:

| Key | Action |
|-----|--------|
| `p` | Pull `main` from origin into the local `main` branch |
| `o` | Open the Xcode project |
| `s` | Configure code signing (writes `Signing.local.xcconfig`) |
| `i` | Build Release and install to `/Applications` |
| `d` | Build Release and create a distributable DMG (optionally notarised) |
| `q` | Quit |

First run should be `s` — it'll prompt for your **Apple Developer Team ID**
and write it to `Signing.local.xcconfig`, which is gitignored so your Team ID
never ends up in the public repo. All subsequent builds (both from Xcode and
from `deploy.sh`) pick it up automatically via the `Signing.xcconfig` cascade.

### Dependencies

Phase 2 of the modernisation plan removed every security-sensitive
third-party Swift package. The app's DSM client, TLS pinning, Keychain
access, and all response parsing are now done against Apple's own
SDKs. One third-party dep remains — **Swifter** — used by
`Webserver.swift` to host the loopback HTTP bridge to the Safari
extension. Phase 3 was to replace the whole bridge with an
`NSXPCConnection` + Safari Web Extension pairing, taking Swifter out
with it and leaving zero third-party runtime dependencies. That work
was blocked and is now abandoned, so **Swifter remains a dependency**
and will not receive updates from this repo.

Dropped during modernisation:
- Alamofire, SwiftyJSON — replaced by `URLSession` + `async/await` +
  `Codable` in Phase 2a
- KeychainAccess — replaced by a direct `SecItem*` wrapper in Phase 2b

### Signing & distribution

- **Debug builds** sign with your `Apple Development` certificate.
- **Release builds** sign with your `Developer ID Application` certificate
  (create one in Xcode → Settings → Accounts → Manage Certificates → **+**
  → *Developer ID Application*).
- **DMGs** are signed, and are **notarised automatically** by `deploy.sh` if
  you've stored notarisation credentials in a keychain profile and written
  the profile name to `.notary-profile-name` (gitignored). Set up once via:

  ```sh
  xcrun notarytool store-credentials "SynologyDSManager-Notary" \
      --apple-id "you@example.com" \
      --team-id  "ABCDE12345" \
      --password "<app-specific-password>"
  echo SynologyDSManager-Notary > .notary-profile-name
  ```

## Project layout

```
SynologyDSManager/            # Main macOS app target
  AppDelegate.swift           # @main SwiftUI App lifecycle + AppDelegate adaptor;
                              #   installs the certificate approval handler
  AppModel.swift              # @Observable app model (state + polling loop)
  Network/                    # DSM API client (Phase 2a)
    SynologyAPI.swift         #   Actor, URLSession + async/await
    SynologyAPIModels.swift   #   Codable DTOs
    SynologyTrustEvaluator.swift # Trust-on-first-use key pinning (see SECURITY.md)
    SynologyError.swift       #   Typed error surface + DSM code mapping
    AppLogger.swift           #   os.Logger categories
  Bridge/                     # XPC bridge to the Safari Web Extension (Phase 3a/3b)
  KeychainStore.swift         # SecItem* wrapper (Phase 2b)
  Settings.swift              # StoredCredentials + Keychain persistence
  Shared.swift                # Stateless utility helpers (bytes/speed formatting)
  Webserver.swift             # Loopback HTTP bridge — unauthenticated; was to be
                              #   removed in Phase 3, which never landed
  ViewControllers/            # SwiftUI views, one per screen, + DestinationPicker
  Localizable.xcstrings       # English String Catalog (localisation scaffolding)

SynologyDSManager Extension/  # Legacy Safari App Extension — replaced in Phase 3
WebExtension/                 # Safari Web Extension source (Phase 3b)

SynologyDSManagerTests/       # macOS unit-test bundle hosted by the app
  URLProtocolStub.swift       # In-memory URLSession fake
  SynologyAPITests.swift      # 23 tests of SynologyAPI, incl. regression-guards
  SynologyBridgeTests.swift   # 10 tests of the XPC bridge
```

## Contributing

**This repository is no longer accepting contributions.** Issues and pull
requests aren't being monitored, so anything opened here will likely sit
unanswered.

If you want to keep the project alive, **fork it** — that's the intended path
forward and no permission is needed. [`CLAUDE.md`](./CLAUDE.md) is a short
orientation to how the codebase is structured and the conventions it follows,
and [`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md) records both what
shipped and what was still outstanding when work stopped.

## Security

**No security reports, please, and do not expect security fixes.** The project
is unmaintained: there is no one triaging reports and no patches will ship.

[`SECURITY.md`](./SECURITY.md) documents the known unfixed issues — an
**unauthenticated loopback HTTP server on port 11863** that any local process
can post download URLs to (and crash the app through), a `synologydsmanager://`
URL scheme that enqueues downloads without validation, the legacy Safari
extension **writing complete download URLs to the unified log**, and a frozen
Swifter dependency. Nothing listens on a network-reachable port — but the
entry points being local doesn't mean an attacker has to be: a website you
visit can invoke the URL-scheme handler with no foothold on your Mac at all.
Each is documented with a mitigation, and none will be fixed here. Read that
file before deciding whether to keep the app installed.

## Acknowledgements

Enormous thanks to **[Anton (@skavans)](https://github.com/skavans)** — without
their work there would be nothing to modernise. They wrote the original macOS
app and Safari extension over several years, shipped it as a paid product to
real customers, incorporated customer feature requests, and then made the
decision to open-source the whole thing under GPL-3.0 when continuing the
commercial side became impractical. That is not a small thing to give away.

The original project — which still contains the history, context, and earlier
user reviews — lives at:

> [github.com/skavans/SynologyDSManager](https://github.com/skavans/SynologyDSManager)

If you are using this fork, please keep that attribution in mind. The code
you are running is built on years of their work.

**Other credits:**

- The app icon originates from Anton's original `Assets.xcassets` (icon set
  by [Icons8](https://icons8.com)). The in-app toolbar icons were replaced
  with SF Symbols during the modernisation, so no third-party icon assets
  remain beyond the app icon.

## Licence

**GNU General Public License v3.0** — see [`LICENSE`](./LICENSE), which is the
authoritative copy.

- Original app, Safari extension, and surrounding code: © 2020–2023
  Anton ([@skavans](https://github.com/skavans)).
- Modernisation work (2024–present): © SynologyDSManager contributors.

Both sets of work are under GPL-3.0. The upstream project
[`skavans/SynologyDSManager`](https://github.com/skavans/SynologyDSManager)
ships a byte-identical GPL-3.0 `LICENSE`, and this fork inherits it.

> **Note for forkers:** GPL-3.0 is a copyleft licence. Keeping a fork private
> commits you to nothing. If you *distribute* a modified version, you must make
> its Corresponding Source available under GPL-3.0 — by any of the routes
> section 6 of the licence allows, which includes shipping the source alongside
> the build, a written offer, or equivalent access from a network server. That
> much is not optional and cannot be relicensed away — not by this fork and not
> by yours — because the copyright in the original work is Anton's.
>
> Earlier revisions of this README, `SECURITY.md`, and the apps' `Info.plist`
> copyright strings incorrectly described the project as MIT licensed. That
> was a documentation error, corrected in August 2026. **The `LICENSE` file
> has been GPL-3.0 for the entire history of both this fork and the upstream
> project** — the licence never changed, only the prose describing it. If you
> forked while the docs said MIT, your obligations are GPL-3.0.
