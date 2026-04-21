# Security policy

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**
Reports in public issues put every user of the app at risk until a fix ships.

Instead, report privately via **GitHub Security Advisories**:

> [Report a vulnerability](https://github.com/lotech/SynologyDSManager/security/advisories/new)

GitHub Security Advisories give us a private space to triage the report,
collaborate on a fix, and coordinate disclosure. They also integrate with
CVE assignment if the issue warrants one.

If you cannot use GitHub Security Advisories for any reason, open a normal
issue titled **"Security: please contact me privately"** with no details,
and a maintainer will follow up with a secure contact channel.

## What to include

A good report has:

- A short description of the issue and why it is a security concern (e.g.
  credential exposure, remote code execution, authentication bypass).
- Steps to reproduce, or a proof of concept.
- The affected version(s) — commit SHA or release tag.
- Your assessment of impact (who can exploit this, and to do what).
- Any suggested mitigation, if you have one.

Please redact real credentials, session IDs, and NAS IP addresses /
hostnames from your report. `user@example.com`, `ABCDE12345`, and
`192.0.2.10` are fine placeholders.

## What counts as a security issue

High-signal areas for this project:

- **Credential handling** — anything that leaks the user's Synology
  username/password, OTP code, or session ID (`_sid`), in memory, on disk,
  over the network, in crash reports, or to third parties.
- **TLS / transport** — certificate validation bypasses, pinning bypasses,
  unsalted downgrade paths, or weak ciphers negotiated with the NAS.
- **Keychain** — items stored without appropriate accessibility flags, or
  items persisted across logout/lock when they shouldn't be.
- **The local HTTP bridge** (`Webserver.swift`) — unauthenticated RCE-adjacent
  paths, request forgery from other local processes, or DoS via malformed
  input. *Note: the bridge is scheduled for removal in Phase 3 of the
  modernisation plan.*
- **URL-scheme handling** (`synologydsmanager://…`) — anything that lets a
  website or another app trigger unintended downloads, file opens, or
  credential prompts.
- **The Safari / Chrome extensions** — cross-site leakage of URLs or
  credentials; messages accepted without origin validation; CSP bypasses.

Out of scope (but still useful as regular issues):

- Denial of service requiring physical access to the user's Mac.
- Theoretical issues with no demonstrable user impact.
- Vulnerabilities in upstream dependencies (Alamofire, SwiftyJSON, etc.).
  Please report those to the upstream maintainers; we will track fixes via
  our dependency bumps.

## Response expectations

This is a hobby-maintained fork with a single core maintainer, so please
set your expectations accordingly. We will:

- **Acknowledge** the report within 7 days.
- **Triage** it and let you know our assessment within 14 days.
- **Fix** confirmed vulnerabilities as quickly as reasonably possible. We
  aim for 90 days from confirmation to public disclosure, or sooner if a
  fix is available sooner.
- **Credit** you in the release notes and in the published advisory,
  unless you prefer to remain anonymous.

## Supported versions

Only the latest `main` branch is supported with security fixes. The
pre-fork releases (`skavans/SynologyDSManager` v1.x) are unmaintained.

## Additional context

- The project is MIT licensed. See [`LICENSE`](./LICENSE).
- The modernisation roadmap, including the phases that address known
  security issues (TLS pinning, Keychain hardening, webserver removal),
  lives in [`MODERNIZATION_PLAN.md`](./MODERNIZATION_PLAN.md).
