//
//  SynologyAPI.swift
//  SynologyDSManager
//
//  Modern replacement for `SynologyClient.swift`. Same observable DSM API
//  surface — `authenticate`, list tasks, start/pause/resume/delete, BT
//  search, directory listing — but built on:
//
//    * `URLSession` rather than Alamofire (no third-party transport)
//    * `async/await` rather than completion-handler pyramids
//    * typed `Codable` models rather than SwiftyJSON
//    * typed `SynologyError` rather than `NSError` stringly-typed descriptions
//    * `SynologyTrustEvaluator` for TLS (SPKI pinning), not `DisabledEvaluator`
//    * cookie-based session auth rather than `_sid=` in URL query strings
//
//  This file does not replace `SynologyClient.swift` yet — both exist in
//  parallel during Phase 2a. Phase 2a-2 migrates every call site over,
//  deletes the old client, and removes Alamofire + SwiftyJSON from SPM.
//

import Foundation
import os

/// Thread-safe DSM API client. Owns the `URLSession` and the current
/// session ID; all mutation is serialised by actor isolation.
actor SynologyAPI {

    // MARK: - Credentials

    struct Credentials: Sendable, Equatable {
        var host: String
        var port: Int
        var username: String
        var password: String
        /// One-time password (TOTP) code, or `nil` if the account doesn't
        /// have 2FA enabled. `""` is treated as `nil`.
        var otp: String?

        var baseURL: URL? {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.port = port
            return components.url
        }
    }

    // MARK: - State

    private let trustEvaluator: SynologyTrustEvaluator
    private let session: URLSession
    private(set) var credentials: Credentials
    private(set) var sessionID: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // DSM returns integers as integers and doubles as doubles — the
        // defaults work fine, nothing to configure.
        return d
    }()

    // MARK: - Construction

    /// Create a DSM API client.
    ///
    /// - Parameters:
    ///   - credentials: host/port/credentials.
    ///   - trustEvaluator: TLS trust evaluator handling the self-signed
    ///     first-use flow. In production pass the shared
    ///     `synologyTrustEvaluator`; in tests the default-constructed
    ///     evaluator with no approval handler is fine because the test
    ///     transport bypasses TLS entirely.
    ///   - configuration: optional pre-built `URLSessionConfiguration`. If
    ///     `nil` (production), we build an ephemeral config with an empty
    ///     in-memory cookie jar and sane timeouts. Tests pass a config
    ///     with `protocolClasses = [URLProtocolStub.self]` so every
    ///     request is intercepted in-process instead of hitting the
    ///     network.
    init(credentials: Credentials,
         trustEvaluator: SynologyTrustEvaluator = SynologyTrustEvaluator(),
         configuration: URLSessionConfiguration? = nil) {
        self.credentials = credentials
        self.trustEvaluator = trustEvaluator

        let config: URLSessionConfiguration
        if let configuration {
            config = configuration
        } else {
            config = URLSessionConfiguration.ephemeral
            // An ephemeral configuration has its own HTTPCookieStorage, so
            // the DSM session cookie lives only in memory. We do not want
            // to persist the `id` cookie between app launches; the user's
            // keychain-stored password re-authenticates each time instead.
            config.httpCookieStorage = HTTPCookieStorage()
            config.httpCookieAcceptPolicy = .always
            config.httpShouldSetCookies = true
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.timeoutIntervalForRequest = 30
        }

        self.session = URLSession(
            configuration: config,
            delegate: trustEvaluator,
            delegateQueue: nil
        )
    }

    /// Replace the stored credentials (e.g. when the user updates settings).
    /// Forgets any existing SID so the next call triggers a fresh login.
    func updateCredentials(_ credentials: Credentials) {
        self.credentials = credentials
        self.sessionID = nil
    }

    // MARK: - Auth

    /// Perform `SYNO.API.Auth login`. Stores the returned SID in both the
    /// in-memory session cookie jar (as `id=<sid>` for the host) and the
    /// actor's `sessionID` property.
    func authenticate() async throws -> String {
        guard let base = credentials.baseURL else { throw SynologyError.invalidURL }
        let url = base.appendingPathComponent("webapi/auth.cgi")

        var body = DSMFormBody()
        body.set("api", "SYNO.API.Auth")
        body.set("version", "3")
        body.set("method", "login")
        body.set("account", credentials.username)
        body.set("passwd", credentials.password)
        body.set("session", "DownloadStation")
        body.set("format", "cookie")
        if let otp = credentials.otp, !otp.isEmpty {
            body.set("otp_code", otp)
        }

        AppLogger.auth.notice("Authenticating to \(self.credentials.host, privacy: .private)")

        let envelope: DSMResponse<AuthSuccessData> = try await post(url: url, body: body, authenticated: false)
        guard envelope.success, let sid = envelope.data?.sid else {
            let code = envelope.error?.code ?? 100
            AppLogger.auth.error("Authentication failed (DSM code \(code))")
            throw SynologyError.api(code: code, message: SynologyErrorCode.message(for: code))
        }

        sessionID = sid
        installSessionCookie(sid: sid)
        AppLogger.auth.notice("Authentication succeeded")
        return sid
    }

    /// Logout and clear the session. Best-effort: network failures are
    /// swallowed (we're invalidating locally regardless).
    func logout() async {
        guard let base = credentials.baseURL, sessionID != nil else { return }
        let url = base.appendingPathComponent("webapi/auth.cgi")

        var body = DSMFormBody()
        body.set("api", "SYNO.API.Auth")
        body.set("version", "3")
        body.set("method", "logout")
        body.set("session", "DownloadStation")

        _ = try? await post(url: url, body: body) as DSMResponse<EmptyData>
        sessionID = nil
        clearSessionCookies()
        AppLogger.auth.notice("Logged out")
    }

    // MARK: - Download tasks

    func listTasks() async throws -> [DSMTask] {
        try requireAuth()
        guard let base = credentials.baseURL else { throw SynologyError.invalidURL }
        let url = base.appendingPathComponent("webapi/DownloadStation/task.cgi")

        var body = DSMFormBody()
        body.set("api", "SYNO.DownloadStation.Task")
        body.set("version", "1")
        body.set("method", "list")
        body.set("additional", "detail,transfer")

        let envelope: DSMResponse<TaskListData> = try await post(url: url, body: body)
        guard envelope.success, let data = envelope.data else {
            throw Self.apiError(envelope)
        }
        return data.tasks
    }

    func pauseTask(id taskID: String) async throws {
        try await simpleTaskAction("pause", taskID: taskID)
    }

    func resumeTask(id taskID: String) async throws {
        try await simpleTaskAction("resume", taskID: taskID)
    }

    func deleteTask(id taskID: String) async throws {
        try await simpleTaskAction("delete", taskID: taskID)
    }

    private func simpleTaskAction(_ method: String, taskID: String) async throws {
        try requireAuth()
        guard let base = credentials.baseURL else { throw SynologyError.invalidURL }
        let url = base.appendingPathComponent("webapi/DownloadStation/task.cgi")

        var body = DSMFormBody()
        body.set("api", "SYNO.DownloadStation.Task")
        body.set("version", "1")
        body.set("method", method)
        body.set("id", taskID)

        // DSM returns a JSON array of per-task results for bulk ops; we
        // don't currently care about individual statuses, only whether the
        // envelope said "success".
        let envelope: DSMResponse<EmptyData> = try await post(url: url, body: body)
        if !envelope.success { throw Self.apiError(envelope) }
    }

    /// Enqueue a new download from a URL (http/https/ftp/magnet/ed2k).
    func createTask(url: String, destination: String?) async throws {
        try requireAuth()
        guard let base = credentials.baseURL else { throw SynologyError.invalidURL }
        let endpoint = base.appendingPathComponent("webapi/DownloadStation/task.cgi")

        var body = DSMFormBody()
        body.set("api", "SYNO.DownloadStation.Task")
        body.set("version", "1")
        body.set("method", "create")
        body.set("uri", url)
        if let destination, !destination.isEmpty {
            body.set("destination", destination.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }

        let envelope: DSMResponse<EmptyData> = try await post(url: endpoint, body: body)
        if !envelope.success { throw Self.apiError(envelope) }
    }

    /// Enqueue a new download by uploading a local `.torrent` file. Uses
    /// `SYNO.DownloadStation2.Task` (multipart) per the DSM 7.x API.
    func createTask(torrentFile: URL, destination: String?) async throws {
        try requireAuth()
        guard let base = credentials.baseURL else { throw SynologyError.invalidURL }

        let fileData: Data
        do {
            fileData = try Data(contentsOf: torrentFile)
        } catch {
            throw SynologyError.torrentFileUnreadable(torrentFile)
        }

        let endpoint = base.appendingPathComponent("webapi/entry.cgi")

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let destField = (destination ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileName = torrentFile.lastPathComponent

        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("api", "SYNO.DownloadStation2.Task")
        appendField("version", "2")
        appendField("method", "create")
        appendField("type", "\"file\"")
        appendField("file", "[\"torrent\"]")
        appendField("create_list", "false")
        appendField("destination", "\"\(destField)\"")

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"torrent\"; filename=\"\(fileName)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-bittorrent\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        AppLogger.network.debug("Uploading torrent file (\(fileData.count, privacy: .public) bytes)")
        let envelope: DSMResponse<EmptyData> = try await perform(request)
        if !envelope.success { throw Self.apiError(envelope) }
    }

    // MARK: - BT search

    /// Run a BT search and return the results once the search completes.
    /// Polls `list` every second until `is_running == false`. Obeys
    /// `Task.checkCancellation()`, so callers can cancel the search.
    func searchTorrents(query: String) async throws -> [BTSearchResult] {
        try requireAuth()
        guard let base = credentials.baseURL else { throw SynologyError.invalidURL }
        let endpoint = base.appendingPathComponent("webapi/entry.cgi")

        var start = DSMFormBody()
        start.set("api", "SYNO.DownloadStation2.BTSearch")
        start.set("version", "1")
        start.set("method", "start")
        start.set("action", "search")
        start.set("keyword", "\"\(query)\"")

        let startEnv: DSMResponse<BTSearchStartData> = try await post(url: endpoint, body: start)
        guard startEnv.success, let searchID = startEnv.data?.id else {
            throw Self.apiError(startEnv)
        }

        while !Task.isCancelled {
            try await Task.sleep(nanoseconds: 1_000_000_000)

            var poll = DSMFormBody()
            poll.set("api", "SYNO.DownloadStation2.BTSearch")
            poll.set("version", "1")
            poll.set("method", "list")
            poll.set("sort_by", "seeds")
            poll.set("order", "DESC")
            poll.set("offset", 0)
            poll.set("limit", 50)
            poll.set("id", "\"\(searchID)\"")

            let env: DSMResponse<BTSearchPollData> = try await post(url: endpoint, body: poll)
            if let data = env.data, !data.isRunning {
                return data.results
            }
        }
        throw CancellationError()
    }

    // MARK: - Directory listing

    func listDirectories(root: String) async throws -> [FileEntry] {
        try requireAuth()
        guard let base = credentials.baseURL else { throw SynologyError.invalidURL }
        let endpoint = base.appendingPathComponent("webapi/entry.cgi")

        var body = DSMFormBody()
        body.set("api", "SYNO.FileStation.List")
        body.set("version", "2")
        body.set("method", "list")
        body.set("filetype", "\"dir\"")
        body.set("folder_path", "\"\(root)\"")

        let envelope: DSMResponse<FileListData> = try await post(url: endpoint, body: body)
        guard envelope.success, let data = envelope.data else {
            throw Self.apiError(envelope)
        }
        return data.files ?? []
    }

    // MARK: - Plumbing

    private func requireAuth() throws {
        guard sessionID != nil else { throw SynologyError.notAuthenticated }
    }

    /// Set the `id=<sid>` cookie on the session's cookie jar so any
    /// endpoint that prefers cookie-based auth sees it. Not authoritative
    /// for us — see the `post(…)` docstring for why we also pass `_sid`
    /// in the POST body — but belt and braces.
    private func installSessionCookie(sid: String) {
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: "id",
            .value: sid,
            .domain: credentials.host,
            .path: "/",
            .secure: true,
        ]
        guard let cookie = HTTPCookie(properties: props) else {
            AppLogger.auth.error("Failed to construct session cookie for \(self.credentials.host, privacy: .private)")
            return
        }
        session.configuration.httpCookieStorage?.setCookie(cookie)
    }

    private func clearSessionCookies() {
        guard let storage = session.configuration.httpCookieStorage,
              let cookies = storage.cookies else { return }
        for cookie in cookies { storage.deleteCookie(cookie) }
    }

    /// POST with a form-encoded body and decode the response envelope.
    ///
    /// When `authenticated` is `true` (the default) and a session ID is
    /// available, `_sid=<sid>` is appended to the body. DSM accepts the
    /// session identifier via three channels — a `Cookie: id=<sid>`
    /// header, a `_sid=<sid>` query parameter, or a `_sid` field in the
    /// POST body — and behaves inconsistently across versions about
    /// which of them it treats as authoritative. In practice sending it
    /// in the POST body is the most reliable for DSM 6.2+ and 7.x, and
    /// has the critical security property of not leaking into URLs /
    /// referer headers / crash reports / proxy logs the way a query
    /// parameter would. We also install a session cookie in
    /// `installSessionCookie(sid:)` as belt-and-braces for any endpoint
    /// that prefers the cookie path.
    ///
    /// `authenticate()` passes `authenticated: false` because that call
    /// is what *creates* the session in the first place.
    private func post<T: Decodable & Sendable>(
        url: URL,
        body: DSMFormBody,
        authenticated: Bool = true
    ) async throws -> DSMResponse<T> {
        var actualBody = body
        if authenticated, let sid = sessionID {
            actualBody.set("_sid", sid)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = actualBody.encoded()
        return try await perform(request)
    }

    /// Shared plumbing: run the request, validate HTTP, decode the envelope,
    /// map URL/decoder errors into `SynologyError`.
    private func perform<T: Decodable & Sendable>(_ request: URLRequest) async throws -> DSMResponse<T> {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            // Surface TLS-pinning failures as a typed error so the UI can
            // route them to the cert-approval flow instead of a generic
            // "cannot connect".
            if error.code == .serverCertificateUntrusted
                || error.code == .cancelled
                || error.code == .secureConnectionFailed {
                throw SynologyError.untrustedServer(
                    reason: "The Download Station server's certificate is not trusted."
                )
            }
            throw SynologyError.transport(error)
        } catch {
            throw SynologyError.transport(URLError(.unknown))
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw SynologyError.http(statusCode: http.statusCode)
        }

        do {
            return try decoder.decode(DSMResponse<T>.self, from: data)
        } catch {
            AppLogger.network.error("Decode failure: \(error.localizedDescription, privacy: .public)")
            throw SynologyError.decoding(error)
        }
    }

    /// Translate a failed envelope into a typed `SynologyError`.
    private static func apiError<T>(_ envelope: DSMResponse<T>) -> SynologyError {
        let code = envelope.error?.code ?? 100
        return .api(code: code, message: SynologyErrorCode.message(for: code))
    }
}

/// Empty payload used for envelopes whose `data` we don't care about.
struct EmptyData: Decodable, Sendable {}
