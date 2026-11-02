// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
import Foundation

struct SteamCloudPermissions: Equatable, Sendable {
    var upload = true
    var download = true
}

/// Valve's client has a combined per-app Cloud switch. Disable its automatic
/// sync when either direction is off; native sync handles the enabled direction.
/// Only edit its local preference with Wine fully stopped.
enum SteamCloudClientSettings {
    static func configure(drive: URL, account: UInt64, appID: Int, permissions: SteamCloudPermissions) throws {
        let file = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
            .appendingPathComponent("userdata/\(account & 0xffff_ffff)/config/localconfig.vdf")
        guard SteamCloudPaths.contained(file, in: drive) else { throw SteamFileError.invalid("Unsafe Steam Cloud settings path.") }
        let fm = FileManager.default
        let original = fm.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        let bytes = try updating(original, appID: appID, enabled: permissions.upload && permissions.download)
        if bytes == original { return }
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = file.appendingPathExtension("winevision-cloud-settings-bak")
        if let original, !fm.fileExists(atPath: backup.path) { try original.write(to: backup, options: .atomic) }
        try bytes.write(to: file, options: .atomic)
    }

    static func updating(_ original: Data?, appID: Int, enabled: Bool) throws -> Data {
        var value: SteamValue = .object([:])
        if let original { var parser = try SteamKeyValues(original); value = try parser.read() }
        let path = ["userlocalconfigstore", "software", "valve", "steam", "apps", String(appID), "cloudenabled"]
        func replace(_ node: SteamValue, _ keys: ArraySlice<String>) throws -> SteamValue {
            guard let key = keys.first else { return .text(enabled ? "1" : "0") }
            guard case .object(var fields) = node else { throw SteamFileError.invalid("Steam's Cloud settings are malformed; they were kept.") }
            fields[key] = try replace(fields[key] ?? .object([:]), keys.dropFirst())
            return .object(fields)
        }
        value = try replace(value, path[...])
        func quote(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func encode(_ node: SteamValue, _ depth: Int) -> String {
            guard case .object(let fields) = node else { return "" }
            let indent = String(repeating: "\t", count: depth)
            return fields.keys.sorted().map { key in
                switch fields[key]! {
                case .text(let text): return indent + quote(key) + "\t\t" + quote(text) + "\n"
                case .object:
                    return indent + quote(key) + "\n" + indent + "{\n" + encode(fields[key]!, depth + 1) + indent + "}\n"
                }
            }.joined()
        }
        return Data(encode(value, 0).utf8)
    }
}
