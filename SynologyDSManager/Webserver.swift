//
//  Webserver.swift
//  SynologyDSManager
//
//  Created by  skavans on 13.08.2020.
//  Copyright © 2020 skavans. All rights reserved.
//

//  ⚠️ SECURITY — KNOWN UNFIXED ISSUE. READ BEFORE REUSING THIS FILE.
//
//  This is an UNAUTHENTICATED HTTP server. From the moment polling starts it
//  accepts any local `POST /add_download` and forwards the URL straight to
//  the NAS, with no authentication of the caller whatsoever. Any process
//  on the machine — including one under a DIFFERENT local user account, since
//  a loopback socket carries no per-account restriction — plus any script or
//  browser page that can reach loopback, can enqueue arbitrary downloads. The
//  handler also force-unwraps the request body and `try!`s the decode, so a
//  malformed POST crashes the app.
//
//  Note the ordering in AppModel.startPolling: this server is started BEFORE
//  authentication is awaited, so the crash above is reachable even when the
//  NAS never accepted the user's credentials. Being signed in is not a gate.
//
//  It binds to loopback only, so it is not reachable from the LAN.
//
//  The replacement (an authenticated XPC bridge — see Bridge/, which does
//  validate its peer's code signature and its input) was built but never went
//  live, because Safari refused to start the Web Extension's service worker.
//  Phase 3c, which would have deleted this file, is ABANDONED — the project
//  is unmaintained as of August 2026. This remains the live code path, and
//  nobody is going to fix it here.
//
//  If you are working in a fork: deleting this file and routing the extension
//  through Bridge/ is the single highest-value change you can make. See
//  SECURITY.md ("Known unfixed issues").

import Foundation

import Swifter


private func handle_new_download_task(request: HttpRequest) -> HttpResponse {
    
    struct message: Codable {
        let url: String
    }
    
    let request_body = String(bytes: request.body, encoding: .utf8)!
    let request_data = request_body.data(using: .utf8)!
    let decoder = JSONDecoder()
    let data = try! decoder.decode(message.self, from: request_data)

    // Swifter invokes this handler on its own background dispatch queue,
    // but `downloadByURLFromExtension` is a main-actor-isolated method
    // on DownloadsViewController. Hop to the main actor explicitly.
    // (This file was to be deleted in Phase 3 once the unauthenticated
    // loopback bridge was replaced with NSXPCConnection. That never
    // happened — see the security note at the top of the file.)
    let url = data.url
    Task { @MainActor in
        AppModel.shared.enqueueDownload(url: url)
    }

    return HttpResponse.raw(200, "OK", [:], {try! $0.write("OK".data(using: String.Encoding.utf8)!)})
}


func start_webserver() {

    let server = HttpServer()

    server["/add_download"] = handle_new_download_task

    // Bind to the loopback interface only. Swifter's default is INADDR_ANY,
    // which would expose this unauthenticated endpoint to anything on the
    // user's LAN; tightening to 127.0.0.1 keeps the legacy Safari App
    // Extension's bridge reachable without inviting LAN peers in. This was
    // meant to go away entirely in Phase 3c; Phase 3c was abandoned, so the
    // loopback bind is the only thing limiting exposure here.
    server.listenAddressIPv4 = "127.0.0.1"
    server.listenAddressIPv6 = "::1"

    do {
        try server.start(11863, forceIPv4: true, priority: DispatchQoS.QoSClass.userInteractive)
        print("Server has started ( port = \(try server.port()) ). Try to connect now...")
    } catch {
        print("Server start error: \(error)")
    }
}
