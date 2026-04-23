//
//  SynologyBridgeTests.swift
//  SynologyDSManagerTests
//
//  Tests for the Phase 3a XPC bridge surface. Covers the things we
//  can exercise in a unit-test bundle without a second process:
//
//    * `SynologyBridgeService` input validation (URL sanitisation)
//    * Success / failure reply plumbing (via a fake synologyAPI set
//      up in the test harness)
//    * `ClientAuthorization`'s team-ID-reading helper against the
//      test host's own code signature
//
//  The "does authorisation refuse a peer with a different team ID"
//  case isn't unit-testable in-process — it needs a second signed
//  binary — so it gets integration-tested in Phase 3b when the
//  native messaging host target lands.
//

import XCTest
@testable import SynologyDSManager


final class SynologyBridgeServiceTests: XCTestCase {

    private var service: SynologyBridgeService!

    override func setUp() async throws {
        URLProtocolStub.reset()
        service = SynologyBridgeService()

        // Give the service a real `synologyAPI` to talk to, backed by
        // the URLProtocol stub so we don't hit the network.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        config.httpCookieStorage = HTTPCookieStorage()

        let api = SynologyAPI(
            credentials: SynologyAPI.Credentials(
                host: "nas.example", port: 5001,
                username: "u", password: "p", otp: nil
            ),
            configuration: config
        )
        URLProtocolStub.respondWithJSON(#"{"success": true, "data": {"sid": "s"}}"#)
        _ = try await api.authenticate()

        await MainActor.run { synologyAPI = api }
    }

    override func tearDown() async throws {
        URLProtocolStub.reset()
        await MainActor.run { synologyAPI = nil }
        service = nil
    }

    // MARK: - URL validation

    func test_enqueueDownload_rejectsEmptyURL() async {
        let (accepted, message) = await reply(forURL: "")
        XCTAssertFalse(accepted)
        XCTAssertNotNil(message)
    }

    func test_enqueueDownload_rejectsWhitespaceOnlyURL() async {
        let (accepted, _) = await reply(forURL: "   \n\t   ")
        XCTAssertFalse(accepted)
    }

    func test_enqueueDownload_rejectsUnsupportedScheme() async {
        let (accepted, _) = await reply(forURL: "javascript:alert(1)")
        XCTAssertFalse(accepted,
            "the service must refuse URL schemes DSM doesn't handle; 'javascript:' in particular would be a nasty exfil primitive if passed through")
    }

    func test_enqueueDownload_rejectsPlainStringWithoutScheme() async {
        let (accepted, _) = await reply(forURL: "ubuntu.iso")
        XCTAssertFalse(accepted)
    }

    func test_enqueueDownload_rejectsAbsurdlyLongInput() async {
        let huge = String(repeating: "a", count: 10_000)
        let (accepted, _) = await reply(forURL: "https://example.com/" + huge)
        XCTAssertFalse(accepted,
            "regression guard: cap input length so a hostile Safari extension can't use this as a buffer-stuffing primitive")
    }

    func test_enqueueDownload_acceptsSupportedSchemes() async {
        // One representative URL per scheme we allow. Using the magnet
        // one to avoid racing a real DSM response: we only care the
        // sanitiser lets it through, not what DSM does.
        URLProtocolStub.respondWithJSON(#"{"success": true}"#)
        let (accepted, message) = await reply(forURL: "magnet:?xt=urn:btih:abc")
        XCTAssertTrue(accepted, "message was: \(message ?? "nil")")
    }

    // MARK: - Forwarding

    func test_enqueueDownload_callsSynologyAPI_onSuccess() async throws {
        URLProtocolStub.respondWithJSON(#"{"success": true}"#)

        let (accepted, _) = await reply(forURL: "https://example.com/ubuntu.iso")
        XCTAssertTrue(accepted)

        // The request we expect is listTasks… no wait, createTask.
        // Inspect the POST body to confirm the forwarded URL.
        // authenticate() was request 0; createTask is 1.
        let fields = URLProtocolStub.formFields(at: 1)
        XCTAssertEqual(fields["uri"], "https://example.com/ubuntu.iso")
        XCTAssertEqual(fields["method"], "create")
        XCTAssertEqual(fields["_sid"], "s")
    }

    func test_enqueueDownload_surfacesDSMErrorsAsReplyMessage() async {
        URLProtocolStub.respondWithJSON(#"{"success": false, "error": {"code": 400}}"#)

        let (accepted, message) = await reply(forURL: "https://example.com/x.iso")
        XCTAssertFalse(accepted)
        XCTAssertNotNil(message)
        // Don't assert exact string — the SynologyError mapping evolves.
        // Just verify we got something non-empty back.
        XCTAssertFalse(message?.isEmpty ?? true)
    }

    func test_enqueueDownload_whenNotSignedIn_repliesFalse() async {
        await MainActor.run { synologyAPI = nil }

        let (accepted, message) = await reply(forURL: "https://example.com/x.iso")
        XCTAssertFalse(accepted)
        XCTAssertEqual(message, "Not signed in to Download Station.")
    }

    // MARK: - Helpers

    /// Wrap the completion-handler-based bridge call in an async
    /// continuation so tests can await the reply.
    private func reply(forURL url: String) async -> (Bool, String?) {
        await withCheckedContinuation { continuation in
            service.enqueueDownload(url: url) { accepted, message in
                continuation.resume(returning: (accepted, message))
            }
        }
    }
}


final class ClientAuthorizationTests: XCTestCase {

    /// `currentTeamID()` reads the running test-host app's Team ID.
    /// We can't assert a specific value (it differs per maintainer's
    /// Signing.local.xcconfig) but we CAN assert basic shape: either
    /// nil (ad-hoc signed / unsigned, which is fine for tests) or a
    /// 10-character alphanumeric Apple Team ID.
    func test_currentTeamID_returnsNilOrValidShape() {
        let teamID = ClientAuthorization.currentTeamID()
        guard let teamID else { return }  // Ad-hoc signed: acceptable.

        XCTAssertEqual(teamID.count, 10,
            "Apple Team IDs are always 10 characters; got \(teamID.count)")
        XCTAssertTrue(teamID.allSatisfy { $0.isLetter || $0.isNumber },
            "Apple Team IDs are alphanumeric; got '\(teamID)'")
    }
}
