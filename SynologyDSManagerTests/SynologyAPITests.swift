//
//  SynologyAPITests.swift
//  SynologyDSManagerTests
//
//  XCTest suite for `SynologyAPI`. Every test runs entirely in-process:
//  `URLProtocolStub` intercepts the URLSession requests the actor
//  makes, returns a canned response, and records what was sent so we
//  can assert on request shape.
//
//  Two explicit goals beyond normal coverage:
//
//  1. Regression guard for Phase 2a-2b bug where listTasks silently
//     returned an empty array because `_sid` wasn't in the POST body.
//     The "body contains _sid" assertions below would have failed
//     immediately against that buggy implementation.
//
//  2. Regression guard for the security property that the SID never
//     appears in a URL query string. The "URL query is clean"
//     assertion on listTasks' request enforces that.
//

import XCTest
@testable import SynologyDSManager

final class SynologyAPITests: XCTestCase {

    private var api: SynologyAPI!

    override func setUp() async throws {
        URLProtocolStub.reset()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        // The actor's install-session-cookie path writes to this storage;
        // giving it a fresh instance keeps tests isolated from each other.
        config.httpCookieStorage = HTTPCookieStorage()

        api = SynologyAPI(
            credentials: SynologyAPI.Credentials(
                host: "nas.example",
                port: 5001,
                username: "someone",
                password: "secret",
                otp: nil
            ),
            configuration: config
        )
    }

    override func tearDown() async throws {
        URLProtocolStub.reset()
        api = nil
    }

    // MARK: - authenticate()

    func test_authenticate_storesSID_onSuccess() async throws {
        URLProtocolStub.respondWithJSON(#"{"success": true, "data": {"sid": "abc123"}}"#)

        let sid = try await api.authenticate()

        XCTAssertEqual(sid, "abc123")
        let stored = await api.sessionID
        XCTAssertEqual(stored, "abc123",
            "authenticate() should store the returned SID on the actor")
    }

    func test_authenticate_throwsAPIError_onFailure() async throws {
        URLProtocolStub.respondWithJSON(#"{"success": false, "error": {"code": 400}}"#)

        do {
            _ = try await api.authenticate()
            XCTFail("Expected .api error")
        } catch let SynologyError.api(code, _) {
            XCTAssertEqual(code, 400)
        } catch {
            XCTFail("Expected .api error, got \(error)")
        }
    }

    func test_authenticate_doesNotIncludeSIDInBody() async throws {
        URLProtocolStub.respondWithJSON(#"{"success": true, "data": {"sid": "abc"}}"#)

        _ = try await api.authenticate()

        let fields = URLProtocolStub.formFields(at: 0)
        XCTAssertNil(fields["_sid"],
            "authenticate() must not send _sid; it's the call that creates the session")
        XCTAssertEqual(fields["account"], "someone")
        XCTAssertEqual(fields["passwd"], "secret")
        XCTAssertEqual(fields["api"], "SYNO.API.Auth")
        XCTAssertEqual(fields["method"], "login")
    }

    func test_authenticate_hitsAuthCGIEndpoint() async throws {
        URLProtocolStub.respondWithJSON(#"{"success": true, "data": {"sid": "s"}}"#)

        _ = try await api.authenticate()

        let url = URLProtocolStub.requests.first?.url
        XCTAssertEqual(url?.host, "nas.example")
        XCTAssertEqual(url?.port, 5001)
        XCTAssertEqual(url?.path, "/webapi/auth.cgi")
        XCTAssertEqual(url?.scheme, "https")
    }

    // MARK: - listTasks()

    func test_listTasks_throwsNotAuthenticated_ifNotLoggedIn() async throws {
        do {
            _ = try await api.listTasks()
            XCTFail("Expected .notAuthenticated")
        } catch SynologyError.notAuthenticated {
            // expected
        } catch {
            XCTFail("Expected .notAuthenticated, got \(error)")
        }
    }

    func test_listTasks_includesSIDInPOSTBody() async throws {
        // REGRESSION GUARD for Phase 2a-2b. Without _sid in the body DSM
        // returns success=true with an empty tasks array silently — no
        // error is raised, so the only way to notice the bug is either
        // manual testing against a real NAS or an assertion exactly like
        // this one.
        URLProtocolStub.respondWithJSONSequence([
            #"{"success": true, "data": {"sid": "the-sid"}}"#,
            #"{"success": true, "data": {"tasks": []}}"#,
        ])

        _ = try await api.authenticate()
        _ = try await api.listTasks()

        let fields = URLProtocolStub.formFields(at: 1)
        XCTAssertEqual(fields["_sid"], "the-sid",
            "listTasks() must include _sid in the POST body — SECURITY-CRITICAL regression guard")
    }

    func test_listTasks_neverPutsSIDInURL() async throws {
        // REGRESSION GUARD for the security property motivating the new
        // SynologyAPI: session IDs must never be serialised into URL
        // query strings (they'd leak into logs, referer headers, crash
        // reports, etc.).
        URLProtocolStub.respondWithJSONSequence([
            #"{"success": true, "data": {"sid": "the-sid"}}"#,
            #"{"success": true, "data": {"tasks": []}}"#,
        ])

        _ = try await api.authenticate()
        _ = try await api.listTasks()

        let url = URLProtocolStub.requests[1].url
        XCTAssertNil(url?.query,
            "listTasks() URL must have no query component — _sid belongs in the body")
        XCTAssertFalse(url?.absoluteString.contains("_sid") ?? true,
            "SID should not appear anywhere in the URL")
    }

    func test_listTasks_decodesTypedTasks() async throws {
        URLProtocolStub.respondWithJSONSequence([
            #"{"success": true, "data": {"sid": "s"}}"#,
            """
            {
              "success": true,
              "data": {
                "tasks": [
                  {
                    "id": "dbid_1",
                    "title": "ubuntu-24.04.iso",
                    "size": 5368709120,
                    "status": "downloading",
                    "additional": {
                      "transfer": {
                        "speed_download": 1048576,
                        "speed_upload": 0,
                        "size_downloaded": 2684354560,
                        "size_uploaded": 0
                      }
                    }
                  },
                  {
                    "id": "dbid_2",
                    "title": "finished.zip",
                    "size": 100,
                    "status": "finished",
                    "additional": null
                  }
                ]
              }
            }
            """,
        ])

        _ = try await api.authenticate()
        let tasks = try await api.listTasks()

        XCTAssertEqual(tasks.count, 2)

        let first = tasks[0]
        XCTAssertEqual(first.id, "dbid_1")
        XCTAssertEqual(first.title, "ubuntu-24.04.iso")
        XCTAssertEqual(first.size, 5_368_709_120)
        XCTAssertEqual(first.status, "downloading")
        XCTAssertTrue(first.isDownloading)
        XCTAssertFalse(first.isFinished)
        XCTAssertFalse(first.isPaused)
        XCTAssertEqual(first.additional?.transfer?.speedDownload, 1_048_576)
        XCTAssertEqual(first.additional?.transfer?.sizeDownloaded, 2_684_354_560)

        let second = tasks[1]
        XCTAssertTrue(second.isFinished)
        XCTAssertNil(second.additional,
            "null JSON values should decode to nil Swift optionals")
    }

    // MARK: - pause / resume / delete

    func test_pauseTask_sendsCorrectRequest() async throws {
        URLProtocolStub.respondWithJSONSequence([
            #"{"success": true, "data": {"sid": "s"}}"#,
            #"{"success": true}"#,
        ])

        _ = try await api.authenticate()
        try await api.pauseTask(id: "dbid_42")

        let fields = URLProtocolStub.formFields(at: 1)
        XCTAssertEqual(fields["api"], "SYNO.DownloadStation.Task")
        XCTAssertEqual(fields["method"], "pause")
        XCTAssertEqual(fields["id"], "dbid_42")
        XCTAssertEqual(fields["_sid"], "s")
    }

    func test_resumeTask_sendsCorrectRequest() async throws {
        URLProtocolStub.respondWithJSONSequence([
            #"{"success": true, "data": {"sid": "s"}}"#,
            #"{"success": true}"#,
        ])

        _ = try await api.authenticate()
        try await api.resumeTask(id: "dbid_42")

        let fields = URLProtocolStub.formFields(at: 1)
        XCTAssertEqual(fields["method"], "resume")
        XCTAssertEqual(fields["id"], "dbid_42")
    }

    func test_deleteTask_sendsCorrectRequest() async throws {
        URLProtocolStub.respondWithJSONSequence([
            #"{"success": true, "data": {"sid": "s"}}"#,
            #"{"success": true}"#,
        ])

        _ = try await api.authenticate()
        try await api.deleteTask(id: "dbid_42")

        let fields = URLProtocolStub.formFields(at: 1)
        XCTAssertEqual(fields["method"], "delete")
        XCTAssertEqual(fields["id"], "dbid_42")
    }

    // MARK: - Error paths

    func test_httpError_surfacesAsSynologyErrorHTTP() async throws {
        URLProtocolStub.respondWithJSON("{}", status: 500)

        do {
            _ = try await api.authenticate()
            XCTFail("Expected .http(500)")
        } catch let SynologyError.http(code) {
            XCTAssertEqual(code, 500)
        } catch {
            XCTFail("Expected .http, got \(error)")
        }
    }

    func test_malformedJSON_surfacesAsDecoding() async throws {
        URLProtocolStub.respondWithJSON("not json at all")

        do {
            _ = try await api.authenticate()
            XCTFail("Expected .decoding")
        } catch SynologyError.decoding {
            // expected
        } catch {
            XCTFail("Expected .decoding, got \(error)")
        }
    }

    func test_transportError_surfacesAsSynologyErrorTransport() async throws {
        URLProtocolStub.respondWithError(.notConnectedToInternet)

        do {
            _ = try await api.authenticate()
            XCTFail("Expected .transport")
        } catch SynologyError.transport {
            // expected
        } catch {
            XCTFail("Expected .transport, got \(error)")
        }
    }

    // MARK: - updateCredentials / logout

    func test_updateCredentials_clearsSessionID() async throws {
        URLProtocolStub.respondWithJSON(#"{"success": true, "data": {"sid": "s"}}"#)
        _ = try await api.authenticate()
        let beforeSID = await api.sessionID
        XCTAssertEqual(beforeSID, "s")

        await api.updateCredentials(SynologyAPI.Credentials(
            host: "nas.example", port: 5001,
            username: "different", password: "newpass", otp: nil
        ))

        let afterSID = await api.sessionID
        XCTAssertNil(afterSID,
            "updateCredentials() must invalidate the cached SID — the next call has to re-auth")
    }

    func test_logout_clearsSessionID() async throws {
        URLProtocolStub.respondWithJSONSequence([
            #"{"success": true, "data": {"sid": "s"}}"#,
            #"{"success": true}"#,
        ])

        _ = try await api.authenticate()
        await api.logout()

        let sid = await api.sessionID
        XCTAssertNil(sid)
    }

    // MARK: - SynologyErrorCode mapping

    func test_errorCodeMessages_coverCommonCodes() {
        // Spot-check: the mapping doesn't need to be exhaustive in tests,
        // but a few well-known codes should round-trip through the
        // mapper so we notice if someone accidentally deletes them.
        XCTAssertTrue(SynologyErrorCode.message(for: 400).contains("password"))
        XCTAssertTrue(SynologyErrorCode.message(for: 403).contains("2-step"))
        XCTAssertTrue(SynologyErrorCode.message(for: 106).contains("timed out"))
        XCTAssertTrue(SynologyErrorCode.message(for: 999_999).contains("999999"),
            "unknown codes should fall through with the raw number visible")
    }
}
