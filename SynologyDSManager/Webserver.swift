//
//  Webserver.swift
//  SynologyDSManager
//
//  Created by  skavans on 13.08.2020.
//  Copyright © 2020 skavans. All rights reserved.
//

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
    // (Whole file is scheduled for deletion in Phase 3 when the
    // unauthenticated loopback bridge is replaced with NSXPCConnection;
    // this is a warnings-clean-up stop-gap.)
    let url = data.url
    Task { @MainActor in
        mainViewController?.downloadByURLFromExtension(URL: url)
    }

    return HttpResponse.raw(200, "OK", [:], {try! $0.write("OK".data(using: String.Encoding.utf8)!)})
}


func start_webserver() {

    let server = HttpServer()

    server["/add_download"] = handle_new_download_task

    // Bind to the loopback interface only. Swifter's default is INADDR_ANY,
    // which would expose this unauthenticated endpoint to anything on the
    // user's LAN; tightening to 127.0.0.1 keeps the legacy Safari App
    // Extension's bridge reachable without inviting LAN peers in. Goes away
    // entirely in Phase 3c when the XPC bridge fully supersedes this file.
    server.listenAddressIPv4 = "127.0.0.1"
    server.listenAddressIPv6 = "::1"

    do {
        try server.start(11863, forceIPv4: true, priority: DispatchQoS.QoSClass.userInteractive)
        print("Server has started ( port = \(try server.port()) ). Try to connect now...")
    } catch {
        print("Server start error: \(error)")
    }
}
