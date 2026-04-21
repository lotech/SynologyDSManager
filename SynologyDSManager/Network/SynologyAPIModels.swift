//
//  SynologyAPIModels.swift
//  SynologyDSManager
//
//  Codable DTOs for the DSM Web API responses we consume. Replaces ad-hoc
//  SwiftyJSON access with typed structs. Every model here is `Sendable`
//  so it can cross actor boundaries without copies.
//
//  Naming convention: DSM returns snake_case keys. We spell the Swift
//  properties camelCase and pair each model with `CodingKeys` to keep
//  call-sites idiomatic. The DTOs mirror the DSM API shape 1:1 — do not
//  add business logic here. Translate into internal model types at the
//  call site if needed.
//

import Foundation

// MARK: - Envelope

/// The standard DSM response envelope. On success `data` is populated; on
/// failure `error` is populated and `success` is `false`.
///
/// `T: Decodable & Sendable` keeps the envelope usable across actor hops.
struct DSMResponse<T: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let data: T?
    let error: DSMErrorPayload?
}

struct DSMErrorPayload: Decodable, Sendable {
    let code: Int
}

// MARK: - Auth

struct AuthSuccessData: Decodable, Sendable {
    let sid: String
}

// MARK: - Download tasks

struct TaskListData: Decodable, Sendable {
    let tasks: [DSMTask]
}

struct DSMTask: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let title: String
    let size: Int64
    let status: String
    let additional: TaskAdditional?

    var isFinished: Bool { status == "finished" }
    var isPaused: Bool { status == "paused" }
    var isDownloading: Bool { status == "downloading" }
}

struct TaskAdditional: Decodable, Sendable, Hashable {
    let transfer: TaskTransfer?
    let detail: TaskDetail?
}

struct TaskTransfer: Decodable, Sendable, Hashable {
    let speedDownload: Int64
    let speedUpload: Int64
    let sizeDownloaded: Int64
    let sizeUploaded: Int64

    enum CodingKeys: String, CodingKey {
        case speedDownload = "speed_download"
        case speedUpload = "speed_upload"
        case sizeDownloaded = "size_downloaded"
        case sizeUploaded = "size_uploaded"
    }
}

struct TaskDetail: Decodable, Sendable, Hashable {
    let destination: String?
    let uri: String?
}

// MARK: - BT search

/// Wrapper used by `SYNO.DownloadStation2.BTSearch` for search *creation*.
/// The initial POST returns `{id: "<searchId>"}`; subsequent polls take
/// that ID and return `BTSearchPoll`.
struct BTSearchStartData: Decodable, Sendable {
    let id: String
}

struct BTSearchPollData: Decodable, Sendable {
    let isRunning: Bool
    let results: [BTSearchResult]

    enum CodingKeys: String, CodingKey {
        case isRunning = "is_running"
        case results
    }
}

struct BTSearchResult: Decodable, Sendable, Identifiable, Hashable {
    /// DSM doesn't return a stable ID on search results; we synthesise one
    /// from `dlurl` so SwiftUI `ForEach` works without extra wrapping.
    var id: String { dlurl }

    let title: String
    let size: Int64
    let date: String
    let seeds: Int
    let peers: Int
    let provider: String
    let dlurl: String
}

// MARK: - File listing (destination picker)

struct FileListData: Decodable, Sendable {
    let files: [FileEntry]?
}

struct FileEntry: Decodable, Sendable, Hashable {
    let name: String
    let path: String
    let isDir: Bool?

    enum CodingKeys: String, CodingKey {
        case name, path
        case isDir = "isdir"
    }
}

// MARK: - Request parameter helpers

/// Small builder for form-encoded POST bodies. DSM's API is form-driven
/// rather than JSON-driven, and we want to avoid the `_sid=` query-string
/// pattern that the old Alamofire client used (SIDs leak into logs, proxy
/// traces, and crash reports). Use this to build a request body.
struct DSMFormBody {
    private(set) var items: [(String, String)] = []

    mutating func set(_ key: String, _ value: String) {
        items.append((key, value))
    }

    mutating func set(_ key: String, _ value: some CustomStringConvertible) {
        items.append((key, String(describing: value)))
    }

    /// Produce `application/x-www-form-urlencoded` body.
    func encoded() -> Data {
        items
            .map { key, value in
                "\(Self.escape(key))=\(Self.escape(value))"
            }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func escape(_ string: String) -> String {
        // Match application/x-www-form-urlencoded: escape everything except
        // unreserved chars. Space → `+` per the form spec.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return string
            .addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? string
    }
}
