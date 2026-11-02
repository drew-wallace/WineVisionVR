// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
import Foundation
import CryptoKit
import zlib

/// Steam may return only a digest/size in PICS, with the actual text VDF at
/// https://<http_host>/appinfo/<appid>/sha/<sha>.txt.gz (SteamKit's HttpUri).
/// This is metadata only and never calls a cloud-save method.
enum SteamPICSMetadata {
    static let maximumBytes = 8 << 20
    static func trustedHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return ["steampowered.com", "steamstatic.com", "steamcontent.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        } && !host.contains(":") && !host.contains("/") && !host.contains("@")
    }
    static func url(appID: UInt32, sha: Data, host: String) -> URL? {
        let authority = host.isEmpty ? "clientconfig.akamai.steamstatic.com" : host
        guard appID > 0, sha.count == 20,
              let endpoint = URLComponents(string: "http://" + authority),
              let name = endpoint.host, trustedHost(name), endpoint.user == nil, endpoint.password == nil,
              endpoint.path.isEmpty, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.port == nil || endpoint.port == 80 || endpoint.port == 443 else { return nil }
        let digest = sha.map { String(format: "%02x", $0) }.joined()
        return URL(string: "https://\(name)/appinfo/\(appID)/sha/\(digest).txt.gz")
    }
    static func decode(_ bytes: Data, expectedSHA: Data) throws -> Data {
        guard bytes.count <= maximumBytes, expectedSHA.count == 20 else { throw SteamFileError.invalid("Steam product info exceeded its size limit.") }
        var decoded = bytes
        if bytes.starts(with: [0x1f, 0x8b]) {
            decoded = Data(count: maximumBytes)
            var stream = z_stream()
            let valid = bytes.withUnsafeBytes { source in
                decoded.withUnsafeMutableBytes { target -> Bool in
                    stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = UInt32(bytes.count)
                    stream.next_out = target.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = UInt32(maximumBytes)
                    guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
                    defer { inflateEnd(&stream) }
                    return inflate(&stream, Z_FINISH) == Z_STREAM_END && stream.total_in == bytes.count
                }
            }
            guard valid else { throw SteamFileError.invalid("Steam product info could not be decompressed.") }
            decoded.count = Int(stream.total_out)
        }
        // Text KV may include its terminal NUL in the served representation.
        let fullSHA = Data(Insecure.SHA1.hash(data: decoded))
        let textSHA = decoded.last == 0 ? Data(Insecure.SHA1.hash(data: decoded.dropLast())) : fullSHA
        guard fullSHA == expectedSHA || textSHA == expectedSHA else { throw SteamFileError.invalid("Steam product info did not match its checksum.") }
        return decoded
    }
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: Redirects(), delegateQueue: nil)
    }()
    static func fetch(_ url: URL) async throws -> Data {
        let (file, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.scheme == "https", trustedHost(http.url?.host ?? ""),
              (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? maximumBytes + 1 <= maximumBytes else {
            throw SteamFileError.invalid("Steam's product info server could not be reached.")
        }
        return try Data(contentsOf: file)
    }
    private final class Redirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            let allowed = request.url?.scheme == "https" && trustedHost(request.url?.host ?? "")
                && request.url?.user == nil && request.url?.password == nil
            completionHandler(allowed ? request : nil)
        }
    }
}
