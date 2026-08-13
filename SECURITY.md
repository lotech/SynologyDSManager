# Security policy

## ⚠️ This project is unmaintained — no security fixes will ship

**Status: unmaintained as of August 2026.**

The maintainer no longer owns a Synology NAS and has stopped work on this
project. There is no one triaging security reports and **no patches will be
released, including for the known issues listed below.**

**Please do not send security reports.** GitHub Security Advisories for this
repository are not being monitored, and neither are issues. A report sent here
will not reach anyone who can act on it — and if the repository is archived,
the private advisory channel is closed entirely. Reporting a live
vulnerability into a channel nobody reads is worse than not reporting it, so
please don't.

If you find a vulnerability in this code, the useful things to do are:

- **Fork the repository and fix it there.** The licence is GPL-3.0, so you're
  free to. Private forks carry no publishing obligation; if you *distribute*
  your build, you must offer its source under GPL-3.0 too. Publishing it
  anyway gives other users somewhere to go.
- **Publish your findings** once you're satisfied users can act on them. There
  is no disclosure embargo to coordinate here — nobody is working on a fix, so
  the usual reason to hold a report private doesn't apply. The only people
  helped by silence would be attackers.

If the issue is in **Synology's DSM API**, **Apple's frameworks**, or the
**Swifter** package rather than in this app's own code, report it to those
projects — they are maintained.

## Known unfixed issues

These were identified during the modernisation audit and are **shipping in
2.2.1 unfixed**. They will not be fixed in this repository. Anyone running or
forking the app should read this list.

**The entry points are local; the trigger need not be.** Nothing here listens on
a network-reachable port — the HTTP server binds loopback only, so it is not
reachable from your LAN or the internet. But "local entry point" is not the same
as "requires an attacker already on your Mac":

- **A website you visit can invoke the `synologydsmanager://` handler** (issue
  2). That is a plain scheme hand-off through Launch Services with no
  same-origin check anywhere in the path, so an attacker needs no foothold on
  your machine at all — just a page you open.
- **A page in your browser may also be able to POST to the loopback server**
  (issue 1). This one is browser-dependent: the response is opaque
  cross-origin, but a fire-and-forget request still reaches the handler, which
  is enough both to enqueue a download and to trigger the crash. Recent
  private-network-access restrictions block this in some browsers and versions,
  so treat it as *possible* rather than guaranteed.

Local code can of course reach both directly — and note that a loopback TCP
socket is **not** restricted to the account that opened it. Any process on the
machine can connect to `127.0.0.1:11863`, including one running under a
*different* local user account. On a shared or multi-user Mac, "local" does not
mean "only you".

Either way, the practical worst case is unwanted downloads queued on your NAS
and an app that crashes — not code execution on your Mac.

**Being signed in is not the gate you might expect.** `AppModel.startPolling`
sets up the API object and calls `start_webserver()` *before* it awaits
authentication, which happens asynchronously afterwards. So once credentials
are configured and polling has started:

- the **crash (denial of service)** in issue 1 is reachable regardless of
  whether the NAS ever accepted your credentials, because `Webserver.swift`
  force-decodes the request body before any session check; and
- the **enqueue** paths only check that an API object exists, not that it is
  authenticated — a failed login still leaves them reachable, though the
  resulting `createTask` call fails at the NAS.

**Quitting the app is a weaker mitigation than it sounds.** Both entry points
need the app running — but a registered URL scheme *starts* it. Opening a
`synologydsmanager://` URL hands off to Launch Services, which launches the app
if it isn't running (the legacy extension's `openAppViaURLScheme` fallback
depends on exactly this), and `applicationDidFinishLaunching` then loads your
stored credentials and calls `startPolling` — which starts the loopback server.

So for anyone with saved credentials, a web page can relaunch a quit app and
bring both entry points back up. Quitting raises the bar; it does not close the
door. Only a rebuild without these paths, or removing the saved credentials,
actually does.

### 1. Unauthenticated loopback HTTP server (`Webserver.swift`)

Once polling starts, it listens on **127.0.0.1 port 11863** — IPv4 only, since
`server.start(…, forceIPv4: true, …)` means the `listenAddressIPv6 = "::1"`
line above it never takes effect and nothing binds `[::1]:11863` — and accepts
any local `POST /add_download` request, with no authentication of any kind.
Any process on the machine — yours, another local user account's, a script, or
a browser page that can reach loopback — can enqueue arbitrary download URLs
onto your NAS. A loopback socket carries no per-account restriction, so on a
multi-user Mac this is not confined to your own session.

The handler also force-unwraps the request body and uses `try!` to decode it,
so a malformed POST crashes the app: a trivially triggered local denial of
service.

It is bound to loopback only, so it is not reachable from your LAN. Phase 3 of
the modernisation plan was to replace it with an authenticated XPC bridge; that
bridge was built and does validate its input (peer code-signature check, scheme
allowlist, length cap), but Safari-side breakage meant it never went live, so
this unauthenticated server is still the code path that actually runs.

**Mitigation:** build your own copy with the `start_webserver()` call removed
from `AppModel.startPolling` (`AppModel.swift`). This costs you **nothing** in
functionality: the legacy extension treats a failed loopback POST as a
fall-through to `openAppViaURLScheme`, so its "send to Download Station" path
keeps working over the URL scheme. By the same token, removing the server does
**not** close issue 2 — the two paths are independent and each needs its own
fix.

Quitting the app helps but does not settle it — see above: a
`synologydsmanager://` URL relaunches the app, and launch loads your stored
credentials and starts the server again.

Removing the stored credentials breaks that chain, but **the app gives you no
way to do it.** Settings offers only "Connect and save settings", which writes
the Keychain item after a successful login; there is no sign-out or clear
action, and `KeychainStore.delete(key:)` — which exists — has no caller
anywhere in the codebase. To actually remove it, use **Keychain Access** (or
`security delete-generic-password -s com.skavans.synologyDSManager`) and delete
the `com.skavans.synologyDSManager` entry by hand. Adding a real sign-out
action is a good first change for a fork.

### 2. Unvalidated `synologydsmanager://` URL scheme

The app registers a custom URL scheme handled in `AppDelegate`. It checks the
URL's shape — host must be `download`, with a non-empty `downloadURL` query
item — but it does **not** authenticate the caller, and it does not validate
the URL it extracts before handing it to the NAS. Any website you visit, or any
local app, can cause a download to be enqueued by handing macOS a
`synologydsmanager://` URL, and the enqueued value is passed through to
`createTask` with no scheme allowlist or length limit. Hardening this was also
deferred to Phase 3.

**Mitigation:** this one needs its own fix — **removing `start_webserver()` does
nothing for it.** The scheme is registered independently, via `CFBundleURLTypes`
in `SynologyDSManager/Info.plist`, and handled independently in
`AppDelegate.application(_:open:)`. To close it in your own build, delete the
`CFBundleURLTypes` entry from `Info.plist` (which unregisters the scheme with
Launch Services), or drop the `case "synologydsmanager":` branch from the
handler, or add validation there — a scheme allowlist plus a length cap,
mirroring `SynologyBridgeService.sanitised`. Copy its list in full if you go
that route: `http://`, `https://`, `ftp://`, `ftps://`, `magnet:` and `ed2k://`.
Trimming it to just the web schemes would break legitimate FTP and ed2k
downloads, which `SynologyAPI.createTask` accepts.
Note that the legacy Safari extension falls back to this scheme when the
loopback POST fails, so removing both leaves that extension with no path to the
app at all — which is fine, since its feature is disabled in the UI regardless.

Short of rebuilding, there is no clean mitigation for this one. Quitting the app
does not settle it, because opening the scheme is itself what relaunches the
app. Deleting the Keychain item by hand is the nearest thing — see issue 1's
mitigation for how, since the app provides no way — after which a launch leaves
the app unauthenticated and an enqueue fails at the NAS.

### 3. The legacy Safari extension logs full URLs to the unified log

`SafariExtensionHandler.messageReceived` (in the bundled
`SynologyDSManager Extension` target) stringifies the entire `userInfo`
dictionary and passes it to `NSLog`, together with the URL of the page the
message came from:

```swift
NSLog("The extension received a message (\(messageName)) from a script injected
       into (\(String(describing: properties?.url))) with userInfo (\(userInfoDescription))")
```

`userInfo` carries the complete download URL under its `URL` key. So every link
you send via that extension — including signed/pre-authenticated URLs with
tokens or credentials in the query string, and the address of the page you sent
it from — lands in the unified log, readable by other processes and captured in
sysdiagnose bundles.

This only fires if you have the legacy extension enabled in Safari. The feature
is disabled in the main app's UI, but the extension target is still built and
embedded in the app bundle, so it can be enabled in Safari's settings
independently. Retiring that target was Phase 3c's job — abandoned.

**Mitigation:** disable "Synology DS Manager" in Safari → Settings → Extensions.

For completeness, `Webserver.swift` also uses bare `print(...)` for its startup
and error paths, against the project's own "no `print` for diagnostics"
convention. Those lines log a port number and an error description, not URLs.

### 4. Swifter is a pinned, unpatched dependency

**Swifter** is the one remaining third-party runtime dependency, and it is the
library serving the loopback HTTP server above. It's pinned in
`Package.resolved` and this repository will not be bumping it, so any future
Swifter vulnerability stays unpatched here. A fork should either update the pin
or, better, finish removing Swifter along with `Webserver.swift`.

### What is *not* on this list

For the record, the things that most often go wrong in an app like this were
addressed during the modernisation and are believed sound:

- **Credentials** are stored in the Keychain via a direct `SecItem*` wrapper
  with `.whenUnlockedThisDeviceOnly` accessibility. Session IDs are never
  persisted across launches.
- **TLS** is never disabled, and self-signed NAS certificates are handled by
  explicit, user-confirmed trust-on-first-use pinning in
  `SynologyTrustEvaluator` rather than by blanket acceptance. Two limits on
  that, both real and neither fixed:
  - **The pin does not constrain CA-issued certificates.** The evaluator asks
    the system first, and returns `.useCredential` the moment
    `SecTrustEvaluateWithError` succeeds — before it ever loads the stored
    pins. A certificate that chains to any system-trusted CA for your host is
    therefore accepted *even if you have already pinned a different key for
    it*. Pin mismatch is refused outright only on the path where system trust
    has already failed, i.e. for self-signed certs. Anyone able to obtain a
    publicly-trusted certificate for your NAS's hostname — plausible for a
    DDNS name under an attacker's control — bypasses the pin silently.
  - **The fingerprint is not an RFC 7469 `pin-sha256` value**, despite earlier
    revisions of this file calling it one. `spkiSHA256Base64` hashes the output
    of `SecKeyCopyExternalRepresentation`, which is the raw key encoding, not
    the DER `SubjectPublicKeyInfo` that RFC 7469 specifies. It is internally
    consistent, so first-use approval and later comparison work — but the
    string shown at approval time will **not** match what standard
    `pin-sha256` tooling computes for the same certificate, so don't try to
    verify it that way.
- **Session IDs** (`_sid`) go in the POST body and the session cookie, never in
  a URL query string. Unit tests guard against a regression there.
- **Logging in the main app's networking and auth code** goes through
  `os.Logger` via `AppLogger` and excludes passwords, OTP codes, session IDs,
  and full request URLs. **This does not extend to the whole codebase** — see
  issue 3 above, where the legacy Safari extension `NSLog`s complete download
  URLs.

**How much of that is actually tested, precisely:** only the `_sid` bullet. The
33 tests in `SynologyDSManagerTests/` cover `SynologyAPI`'s request and session
behaviour — including explicit regression guards that a session ID never
reaches a request URL — plus the XPC bridge's input validation. The suite
contains **no** reference to `KeychainStore`, `SynologyTrustEvaluator`, or
`AppLogger`, so the Keychain-accessibility, TLS-pinning, and logging claims
above rest on **reading the code, not on executing it**.

Treat them accordingly: they are audit findings from a maintainer who has now
stopped, not test-backed guarantees, and nothing re-checks them from here. If
you fork, they are the first things worth writing tests around.

## Repository hygiene

For anyone auditing or forking: this repository was swept before being wound
down — working tree and every blob in the git history — and contains no
credentials, API tokens, private keys, provisioning profiles, notarisation
credentials, LAN IP addresses, or NAS hostnames.

**One exception, on Apple Developer Team IDs:** the sweep found exactly one,
noted below. No Team ID belonging to *this* fork's maintainer appears anywhere,
in the tree or the history.

Signing configuration deliberately keeps Team IDs out of version control via
the `Signing.xcconfig` → gitignored `Signing.local.xcconfig` cascade. If you
fork this, keep that arrangement: put your own Team ID in
`Signing.local.xcconfig` only.

**The exception, stated plainly:** the *upstream* author's Apple Team ID
(`GVS9699BGK`) does appear in the git history — in two older revisions of
`CHANGELOG.md` and `MODERNIZATION_PLAN.md`, in entries describing its removal
from the project file. It is redacted in the current tree, but it is still
retrievable from history, so "no Team IDs anywhere" would be false. It is not
treated as a leak — Apple Team IDs are not secret and appear in the code
signature of every app that team has ever shipped — so the history has been
left intact rather than rewritten.

## Supported versions

**None.** No version of this app is receiving security support.

The pre-fork releases (`skavans/SynologyDSManager` v1.x) are likewise
unmaintained.

## Additional context

- The project is licensed under **GPL-3.0**. See [`LICENSE`](./LICENSE).
  (Earlier revisions of this file described it as MIT — that was a
  documentation error, corrected in August 2026. The `LICENSE` file itself has
  always been GPL-3.0.)
- [`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md) records the security work
  that shipped (TLS pinning, Keychain hardening, dependency removal) and the
  work that didn't (webserver removal, URL-scheme validation).
