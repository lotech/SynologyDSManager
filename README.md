# SynologyDSManager

A native macOS app (and Safari extension) for managing a Synology DownloadStation remotely.

This is a maintained fork of the excellent original project by
[**Anton (@skavans)**](https://github.com/skavans), which lived at
[**skavans/SynologyDSManager**](https://github.com/skavans/SynologyDSManager) from
2020 through 2023. Anton built the whole app — the DSM API client, the Cocoa
UI, the Safari extension, the BT search flow, keychain-backed credentials,
2FA support, and everything else you see on screen. The app was originally
a paid product sold through Paddle, and when that payment channel stopped
working for sellers in Russia in 2022, Anton open-sourced the project rather
than letting it fade away. That generosity is the only reason this fork
exists, and the only reason the code has a second life.

Goals of this fork:

- modernise the codebase (SwiftUI, Swift concurrency, current macOS APIs)
- run a full security audit and fix the outstanding issues
- add new features after the modernisation baseline is in place

See [`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md) for the phased roadmap and
[`CHANGELOG.md`](./CHANGELOG.md) for a running list of changes.

## Features

- Browse, pause, resume, and delete Download Station tasks from a native Mac window
- Add new tasks from `.torrent` files, magnet links, or direct URLs — in bulk
- Pick any shared folder on the NAS as the download destination
- Search BT trackers directly from the app and enqueue results in one click
- Menu-bar status item with live bandwidth readout
- Safari extension: "Download with Synology DS Manager" from the page context menu
- 2-step verification (TOTP) supported

## Requirements

- macOS 13 (Ventura) or newer
- Xcode 15 or newer to build
- A reachable Synology DSM 6.2+ installation with Download Station installed

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

Swift Package dependencies are resolved automatically by Xcode. Remaining
third-party dependencies (Alamofire + SwiftyJSON were removed in Phase 2a-2d):

- KeychainAccess — credential storage; replaced with a direct `SecItem*`
  wrapper in Phase 2b.
- Swifter — backs the unauthenticated loopback HTTP bridge used by the
  Safari App Extension; goes away in Phase 3 along with the whole
  extension-to-XPC migration.

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
  AppDelegate.swift
  SynologyClient.swift        # DSM API client (to be rewritten in Phase 2)
  Settings.swift              # Keychain-backed credential store
  Webserver.swift             # Local HTTP bridge (to be removed in Phase 3)
  ViewControllers/            # Cocoa controllers (to be ported to SwiftUI in Phase 4)
  Base.lproj/Main.storyboard

SynologyDSManager Extension/  # Legacy Safari App Extension (to be migrated in Phase 3)
```

## Contributing

Issues and PRs are welcome. Please read [`CLAUDE.md`](./CLAUDE.md) for a short
orientation to how the codebase is structured and the conventions we're moving
towards, and check [`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md) to see where
your change fits.

## Security

Report security issues privately via GitHub Security Advisories rather than
public issues, especially anything involving credential handling, TLS, the local
HTTP bridge, or the Safari extension's URL-scheme fallback.

## Acknowledgements

Enormous thanks to **[Anton (@skavans)](https://github.com/skavans)** — without
their work there would be nothing to modernise. They wrote the original macOS
app and Safari extension over several years, shipped it as a paid product to
real customers, incorporated customer feature requests, and then made the
decision to release the whole thing under MIT when continuing the commercial
side became impractical. That is not a small thing to give away.

The original project — which still contains the history, context, and earlier
user reviews — lives at:

> [github.com/skavans/SynologyDSManager](https://github.com/skavans/SynologyDSManager)

If you are using this fork, please keep that attribution in mind. The code
you are running is built on years of their work.

**Other credits:**

- Toolbar and app icons originally by [Icons8](https://icons8.com), via
  Anton's original `Assets.xcassets`.
- `LoadableView.swift` is adapted from a tutorial by Gabriel Theodoropoulos
  on Appcoda (© 2019).

## Licence

MIT — see [`LICENSE`](./LICENSE).

- Original app, Safari extension, and surrounding code: © 2020–2023
  Anton ([@skavans](https://github.com/skavans)).
- Modernisation work (2024–present): © SynologyDSManager contributors.

Both sets of work are released under the MIT licence; the `LICENSE` file in
this repository is the authoritative copy.
