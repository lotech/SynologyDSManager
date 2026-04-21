//
//  SynologyError.swift
//  SynologyDSManager
//
//  Typed error surface for the DSM API client. Every failure mode the
//  client can hit lands here — transport failures, HTTP status errors,
//  decoder errors, DSM-specific error codes, authentication state problems,
//  and TLS trust failures.
//

import Foundation

/// Every way a `SynologyAPI` call can fail.
///
/// `Sendable` because callers may observe these across actor hops (e.g.
/// from the `SynologyAPI` actor back into a `@MainActor` view controller).
enum SynologyError: LocalizedError, Sendable {
    /// The underlying `URLSession` call threw a `URLError` — usually a
    /// connectivity problem (offline, DNS, timeout).
    case transport(URLError)

    /// The server returned a non-2xx HTTP status.
    case http(statusCode: Int)

    /// The response body could not be decoded into the expected shape.
    /// The underlying decoder error is stored for diagnostics but is not
    /// surfaced to the user (it tends to be noisy).
    case decoding(Error)

    /// DSM returned a structured API error. `code` is the numeric code
    /// Synology publishes in its Web API documentation; `message` is our
    /// human-readable mapping for known codes.
    case api(code: Int, message: String)

    /// A method was called that needs a session before authentication has
    /// completed, or the server signalled that the session expired.
    case notAuthenticated

    /// The DSM response advertised a successful authentication but did not
    /// contain a session ID. Should be impossible with real DSM builds.
    case missingSessionID

    /// A URL could not be constructed from the supplied host/port/path.
    /// Usually indicates a malformed host string.
    case invalidURL

    /// TLS trust evaluation refused the server's certificate. See
    /// `SynologyTrustEvaluator` for the decision logic. `reason` is a
    /// short human-readable string suitable for a dialog.
    case untrustedServer(reason: String)

    /// A torrent file could not be read from disk.
    case torrentFileUnreadable(URL)

    var errorDescription: String? {
        switch self {
        case .transport(let error):
            return error.localizedDescription
        case .http(let code):
            return "HTTP \(code) from DSM."
        case .decoding:
            // Intentionally generic — the underlying error is for logs, not users.
            return "The Download Station server returned an unexpected response."
        case .api(let code, let message):
            return "\(message) (DSM error \(code))"
        case .notAuthenticated:
            return "Not signed in to Download Station."
        case .missingSessionID:
            return "Download Station accepted the sign-in but returned no session."
        case .invalidURL:
            return "Invalid host or port."
        case .untrustedServer(let reason):
            return reason
        case .torrentFileUnreadable(let url):
            return "Could not read torrent file at \(url.path)."
        }
    }
}

// MARK: - DSM error-code mapping

/// Translate a numeric DSM error code returned alongside `success: false`
/// into a human-readable message. Covers the common codes from
/// `SYNO.API.Auth`, `SYNO.DownloadStation.*`, and `SYNO.FileStation.*` as
/// of DSM 7.2. Unknown codes fall through to a generic message.
///
/// Source: DSM 7.x Developer's Guide — SYNO.API.Auth error table.
enum SynologyErrorCode {
    static func message(for code: Int) -> String {
        switch code {
        // Common
        case 100: return "Unknown error."
        case 101: return "Invalid parameter."
        case 102: return "The requested API does not exist."
        case 103: return "The requested method does not exist."
        case 104: return "The requested version of the API is not supported."
        case 105: return "The logged-in session does not have permission."
        case 106: return "Session timed out."
        case 107: return "Session interrupted by a duplicate login."
        case 119: return "SID not found."

        // SYNO.API.Auth
        case 400: return "Incorrect account or password."
        case 401: return "Account is disabled."
        case 402: return "Permission denied."
        case 403: return "2-step verification code required."
        case 404: return "Failed to authenticate the 2-step verification code."
        case 406: return "Enforce 2-step verification first."
        case 407: return "Blocked by IP."
        case 408: return "Password expired."
        case 409: return "Password must be changed."
        case 410: return "Password must be reset."

        // SYNO.DownloadStation.Task
        case 408_000: return "File upload failed."
        case 544: return "Task already exists."

        default:
            return "DSM returned error code \(code)."
        }
    }
}
