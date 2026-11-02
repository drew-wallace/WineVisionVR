// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
// Cloud protocol adapted from Madeira 48f976429c189f8396e23d251d8a82f43c705922.
// See third-party/steam-native/COPYING and LICENSE-EXCEPTION.md.

import Foundation
import CryptoKit

/// Native sync owns the account only before/after the guest client. No cloud
/// deletion API is used. State is scoped to Valve's authenticated account ID.
@MainActor
final class SteamGameServices {
    struct Record: Codable {
        var restored = false
        var baseline: [String: String] = [:]
        var pendingUpload = false
        // Optional fields preserve older journals. uploadsBlocked imports a
        // temporary device-side hold; an explicit toggle replaces that value.
        var uploadsBlocked: Bool?
        var uploadSaves: Bool?
        var downloadSaves: Bool?
        var resetID: UUID?
        var requiresCloudRestore: Bool?
        var permissions: SteamCloudPermissions {
            .init(upload: uploadSaves ?? (uploadsBlocked != true), download: downloadSaves ?? true)
        }
        var clientPermissions: SteamCloudPermissions {
            var allowed = permissions
            // Do not expose a reset directory to Valve's automatic sync before
            // a verified restore, even if both UI toggles have been re-enabled.
            if requiresCloudRestore == true { allowed.upload = false }
            return allowed
        }
    }
    private let session: SteamCMSession
    private let support: URL
    private let drive: URL
    private let clientRoot: URL
    private let idle: () -> Bool
    // Scripted transports allow sync/recovery tests without contacting Steam.
    var downloadFile: ((Int, SteamCloudEntry) async throws -> Data)?
    var sendUpload: ((Data, [SteamCloudUploadBlock]) async throws -> Void)?

    init(session: SteamCMSession, drive: URL = MadeiraDock.drive,
         support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SteamGameServices-v1"),
         idle: @escaping () -> Bool = { wine_process_is_running() == 0 && wineserver_is_running() == 0 }) {
        self.session = session; self.drive = drive; self.support = support; self.idle = idle
        clientRoot = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot)
    }

    private func check(_ account: UInt64) throws {
        try Task.checkCancellation()
        guard idle(), account != 0, session.steamID == account else {
            throw SteamFileError.invalid("Steam saves are waiting for the game and Steam client to close.")
        }
    }
    private func recordURL(_ appID: Int, _ account: UInt64) -> URL {
        support.appendingPathComponent("\(account)/\(appID).json")
    }
    func record(_ appID: Int, account: UInt64) throws -> Record {
        let url = recordURL(appID, account)
        guard FileManager.default.fileExists(atPath: url.path) else { return Record() }
        // A corrupt journal must never authorize uploading old saves.
        return try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
    }
    func permissions(_ appID: Int, account: UInt64) throws -> SteamCloudPermissions {
        try record(appID, account: account).permissions
    }

    func setPermissions(_ appID: Int, account: UInt64, upload: Bool? = nil, download: Bool? = nil) throws {
        guard idle(), account != 0 else { throw SteamFileError.invalid("Close the game before changing cloud save settings.") }
        var value = try record(appID, account: account)
        if let upload {
            value.uploadSaves = upload
            value.uploadsBlocked = nil
            if !upload { value.pendingUpload = false }
        }
        if let download { value.downloadSaves = download }
        // Persist the user's choice before changing the guest preference, so
        // failure can never silently re-enable an upload they just turned off.
        try store(value, appID, account)
        try SteamCloudClientSettings.configure(drive: drive, account: account, appID: appID, permissions: value.clientPermissions)
    }

    func prepareClientSettings(_ appID: Int) throws {
        let account = session.steamID
        try check(account)
        try SteamCloudClientSettings.configure(drive: drive, account: account, appID: appID,
                                               permissions: try record(appID, account: account).clientPermissions)
    }

    private func requireDirection(_ appID: Int, account: UInt64, upload: Bool, resetID: UUID?) throws {
        try check(account)
        let current = try record(appID, account: account)
        guard current.resetID == resetID else { throw SteamFileError.invalid("Save sync was cancelled by a local reset.") }
        let allowed = current.permissions
        guard upload ? allowed.upload : allowed.download else {
            throw SteamFileError.invalid(upload ? "Save uploads are off for this game." : "Save downloads are off for this game.")
        }
    }

    private func store(_ value: Record, _ appID: Int, _ account: UInt64) throws {
        let url = recordURL(appID, account)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    func markPending(_ appID: Int) throws {
        let account = session.steamID
        try check(account)
        var value = try record(appID, account: account)
        guard value.permissions.upload else { return }
        guard value.restored else { throw SteamFileError.invalid("Synchronize Steam saves before starting this game.") }
        value.pendingUpload = true
        try store(value, appID, account)
    }
    func pendingApps() throws -> [Int] {
        let account = session.steamID
        let directory = support.appendingPathComponent("\(account)")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).compactMap {
            guard $0.hasSuffix(".json"), let id = Int($0.dropLast(5)),
                  try record(id, account: account).pendingUpload,
                  try record(id, account: account).permissions.upload else { return nil }
            return id
        }
    }
    private func listing(_ appID: Int) async throws -> SteamCloudListing {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: UInt32(appID))
        request.writeUInt64(fieldNumber: 2, value: 0)
        return try SteamCloudListing.parse(try await session.callServiceMethod(
            method: .cloudGetAppFileChangelist, body: request.data, timeout: 30))
    }
    private func cloudFile(_ appID: Int, _ entry: SteamCloudEntry) async throws -> Data {
        if let downloadFile {
            let bytes = try await downloadFile(appID, entry)
            guard UInt64(bytes.count) == entry.cloudSize, Data(Insecure.SHA1.hash(data: bytes)) == entry.cloudSHA else {
                throw SteamFileError.invalid("A cloud save did not match its checksum.")
            }
            return bytes
        }
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: UInt32(appID))
        request.writeString(fieldNumber: 2, value: entry.path)
        let info = try SteamCloudDownloadInfo.parse(try await session.callServiceMethod(
            method: .cloudClientFileDownload, body: request.data, timeout: 30))
        return try await SteamCloudTransfer.fetch(info, expectedSHA: entry.cloudSHA)
    }
    private func paths(game: DockGame, info: SteamAppInfo, account: UInt64, user: URL) -> SteamCloudPaths {
        SteamCloudPaths(drive: drive, userFolder: user,
            installFolder: drive.appendingPathComponent(game.library + "/common/" + game.installDir),
            remoteFolder: clientRoot.appendingPathComponent("userdata/\(account & 0xffff_ffff)/\(game.id)/remote"),
            steamID: account, overrides: info.rootOverrides)
    }

    /// Called only by the confirmed local-reset action. Disable both native and
    /// Valve-client sync durably before touching files. The only network request
    /// is a read-only listing, needed to identify API and root-mapped saves.
    func resetLocalSaves(game: DockGame, info: SteamAppInfo) async throws -> Int {
        let account = session.steamID
        try check(account)
        var saved = try record(game.id, account: account)
        saved.uploadSaves = false; saved.downloadSaves = false; saved.uploadsBlocked = nil
        saved.pendingUpload = false; saved.baseline = [:]; saved.restored = false
        saved.resetID = UUID(); saved.requiresCloudRestore = true
        try store(saved, game.id, account)
        try SteamCloudClientSettings.configure(drive: drive, account: account, appID: game.id, permissions: saved.permissions)
        let remote = try await listing(game.id)
        try check(account)
        let current = try record(game.id, account: account)
        guard current.resetID == saved.resetID, !current.permissions.upload, !current.permissions.download else {
            throw SteamFileError.invalid("Local reset stopped because cloud settings changed. No saves were removed.")
        }
        let users = drive.appendingPathComponent("users")
        let names = try FileManager.default.contentsOfDirectory(atPath: users.path)
        let mappings = names.filter { !$0.hasPrefix(".") && $0.lowercased() != "public" }.map {
            paths(game: game, info: info, account: account, user: users.appendingPathComponent($0))
        }
        guard !mappings.isEmpty else { throw SteamFileError.invalid("No Windows save folder was found. No saves were removed.") }
        // Fully validate every candidate before deleting any file. No suspension
        // is allowed between this check and removal, so a launch cannot race it.
        let files = try SteamLocalSaveReset.files(listing: remote, saveFiles: info.saveFiles, mappings: mappings)
        for file in files { try FileManager.default.removeItem(at: file) }
        return files.count
    }

    /// First use is a cloud-authoritative reset, explicitly requested for this
    /// migration. Stage every download before removing any legacy local save.
    /// Later syncs use a three-way comparison and refuse ambiguous overwrites.
    func sync(game: DockGame, info: SteamAppInfo, preferCloud: Bool = false) async throws -> String {
        let account = session.steamID
        try check(account)
        var saved = try record(game.id, account: account)
        let allowed = saved.permissions
        if !allowed.upload && !allowed.download { return "Save uploads and downloads are off" }
        if saved.requiresCloudRestore == true && !allowed.download {
            throw SteamFileError.invalid("Restore cloud saves with Download saves on before enabling uploads after a reset.")
        }
        if preferCloud && !allowed.download { throw SteamFileError.invalid("Turn on Download saves before restoring the cloud copy.") }
        guard let user = SteamCloudPaths.userFolder(drive: drive) else {
            throw SteamFileError.invalid("The Windows save folder is missing. Prepare Valve client first.")
        }
        let paths = paths(game: game, info: info, account: account, user: user.url)
        let remote = try await listing(game.id)
        try check(account)
        let audit = SteamCloudAudit.run(listing: remote, saveFiles: info.saveFiles, paths: paths)
        guard audit.unmapped.isEmpty else {
            throw SteamFileError.invalid("Some Steam Cloud saves cannot be mapped safely to Windows. Launch is paused to protect your saves.")
        }
        let plan = SteamCloudPlan.make(audit: audit, baseline: saved.baseline)
        if saved.restored, allowed.upload, !preferCloud, !plan.conflicts.isEmpty {
            throw SteamFileError.invalid("Steam Cloud and local saves conflict. Use cloud saves in the game's Steam panel to restore the cloud copy.")
        }
        let firstRestore = !saved.restored && allowed.download
        let downloads = !allowed.download ? [] : (firstRestore ? audit.entries.filter { $0.kind != .localOnly } :
            (plan.download + (preferCloud ? audit.entries.filter { $0.kind == .differ || $0.kind == .cloudOnly } : [])))
        let wantedDownloads = Dictionary(downloads.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }).values.sorted { $0.key < $1.key }
        let stage = support.appendingPathComponent("Staging/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        var staged: [(SteamCloudEntry, URL)] = []
        for (index, entry) in wantedDownloads.enumerated() {
            try requireDirection(game.id, account: account, upload: false, resetID: saved.resetID)
            let bytes = try await cloudFile(game.id, entry)
            try requireDirection(game.id, account: account, upload: false, resetID: saved.resetID)
            let file = stage.appendingPathComponent(String(index))
            try bytes.write(to: file, options: .atomic)
            staged.append((entry, file))
        }
        // No suspension between rechecking the local safety boundary and writes.
        let backup = support.appendingPathComponent("Backups/\(account)/\(game.id)/\(UUID().uuidString)")
        if firstRestore {
            try requireDirection(game.id, account: account, upload: false, resetID: saved.resetID)
            // Enumerate each existing Wine user, not just the current user; old
            // development prefixes may have used a different username.
            let users = drive.appendingPathComponent("users")
            let names = try FileManager.default.contentsOfDirectory(atPath: users.path)
            var victims = Set<URL>()
            for name in names where !name.hasPrefix(".") && name.lowercased() != "public" {
                let other = self.paths(game: game, info: info, account: account, user: users.appendingPathComponent(name))
                let local = SteamCloudAudit.run(listing: remote, saveFiles: info.saveFiles, paths: other)
                for entry in local.entries {
                    if let place = other.location(cloudPath: entry.path) {
                        victims.insert(SteamCloudPaths.resolve(base: place.base, parts: place.parts))
                    }
                }
            }
            for url in victims where FileManager.default.fileExists(atPath: url.path) {
                guard SteamCloudPaths.contained(url, in: drive) else { throw SteamFileError.invalid("Unsafe local save path.") }
                try FileManager.default.removeItem(at: url)
            }
            let cache = paths.remoteFolder.deletingLastPathComponent().appendingPathComponent("remotecache.vdf")
            guard SteamCloudPaths.contained(cache, in: drive) else { throw SteamFileError.invalid("Unsafe Steam cache path.") }
            if FileManager.default.fileExists(atPath: cache.path) { try FileManager.default.removeItem(at: cache) }
            saved.baseline = [:]
        }
        for (entry, file) in staged {
            try requireDirection(game.id, account: account, upload: false, resetID: saved.resetID)
            let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
            guard let place = paths.location(cloudPath: entry.path) else { throw SteamFileError.invalid("Unsafe save destination.") }
            let target = SteamCloudPaths.resolve(base: place.base, parts: place.parts)
            try SteamCloudTransfer.place(bytes, at: target, backupTo: backup,
                relative: [SteamCloudPaths.split(entry.path).root ?? "remote"] + place.parts, time: entry.cloudTime)
        }
        // First restore never uploads, even with an empty remote listing.
        let uploads = !firstRestore && !preferCloud && allowed.upload ? plan.upload : []
        if !uploads.isEmpty {
            try await upload(game: game, info: info, paths: paths, entries: uploads,
                             remote: remote, backup: backup, account: account, resetID: saved.resetID)
        }
        let after = try await listing(game.id)
        try check(account)
        let verified = SteamCloudAudit.run(listing: after, saveFiles: info.saveFiles, paths: paths)
        let transferred = Set(wantedDownloads.map(\.key) + uploads.map(\.key))
        guard verified.unmapped.isEmpty,
              !verified.entries.contains(where: { transferred.contains($0.key) && $0.kind != .same }) else {
            throw SteamFileError.invalid("Steam saves changed during synchronization. Retry Sync saves.")
        }
        for entry in verified.entries where entry.kind == .same { saved.baseline[entry.key] = SteamCloudPlan.hex(entry.cloudSHA) }
        // Keep settings changed while a transfer was awaiting the network.
        let current = try record(game.id, account: account)
        guard current.resetID == saved.resetID else { throw SteamFileError.invalid("Save sync was cancelled by a local reset.") }
        saved.uploadSaves = current.uploadSaves; saved.downloadSaves = current.downloadSaves
        saved.uploadsBlocked = current.uploadsBlocked
        saved.restored = true; saved.pendingUpload = false
        if allowed.download { saved.requiresCloudRestore = false }
        try store(saved, game.id, account)
        try SteamCloudClientSettings.configure(drive: drive, account: account, appID: game.id, permissions: saved.clientPermissions)
        if !allowed.upload { return "Downloads checked; save uploads are off" }
        if !allowed.download { return "Uploads checked; save downloads are off" }
        return firstRestore ? "Cloud saves restored; old local saves cleared" : "Steam Cloud up to date"
    }

    private func upload(game: DockGame, info: SteamAppInfo, paths: SteamCloudPaths,
                        entries: [SteamCloudEntry], remote: SteamCloudListing, backup: URL, account: UInt64, resetID: UUID?) async throws {
        try requireDirection(game.id, account: account, upload: true, resetID: resetID)
        // Back up the previous cloud bytes before an overwrite, and reject a
        // changed server generation. No files_to_delete field is ever sent.
        let keepCloudBackups = try permissions(game.id, account: account).download
        for entry in entries where !entry.cloudSHA.isEmpty && keepCloudBackups {
            try requireDirection(game.id, account: account, upload: true, resetID: resetID)
            try requireDirection(game.id, account: account, upload: false, resetID: resetID)
            let bytes = try await cloudFile(game.id, entry)
            try requireDirection(game.id, account: account, upload: false, resetID: resetID)
            guard let place = paths.location(cloudPath: entry.path) else { throw SteamFileError.invalid("Unsafe cloud path.") }
            let target = ([SteamCloudPaths.split(entry.path).root ?? "remote"] + place.parts)
                .reduce(backup.appendingPathComponent("cloud")) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
        guard try await listing(game.id) == remote else { throw SteamFileError.invalid("Steam Cloud changed on another device. Retry sync.") }
        try requireDirection(game.id, account: account, upload: true, resetID: resetID)
        var begin = ProtobufEncoder()
        begin.writeUInt32(fieldNumber: 1, value: UInt32(game.id))
        begin.writeString(fieldNumber: 2, value: "WineVision VR")
        for entry in entries { begin.writeString(fieldNumber: 3, value: entry.path) }
        begin.writeUInt64(fieldNumber: 6, value: UInt64(info.buildID))
        var decoder = ProtobufDecoder(try await session.callServiceMethod(method: .cloudBeginAppUploadBatch, body: begin.data, timeout: 30))
        var batch: UInt64 = 0
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == 1, tag.wireType == .varint { batch = try decoder.readVarint() }
            else { try decoder.skip(wireType: tag.wireType) }
        }
        guard batch != 0 else { throw SteamFileError.invalid("Steam refused the save upload batch.") }
        do {
            for entry in entries {
                try requireDirection(game.id, account: account, upload: true, resetID: resetID)
                guard let place = paths.location(cloudPath: entry.path) else { throw SteamFileError.invalid("Unsafe save path.") }
                let url = SteamCloudPaths.resolve(base: place.base, parts: place.parts)
                let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
                let sha = Data(Insecure.SHA1.hash(data: bytes))
                guard bytes.count <= SteamCloudTransfer.maxFileBytes, sha == entry.localSHA else {
                    throw SteamFileError.invalid("The game save changed during upload. Retry sync.")
                }
                var request = ProtobufEncoder()
                request.writeUInt32(fieldNumber: 1, value: UInt32(game.id))
                request.writeUInt32(fieldNumber: 2, value: UInt32(bytes.count))
                request.writeUInt32(fieldNumber: 3, value: UInt32(bytes.count))
                request.writeBytes(fieldNumber: 4, value: sha)
                request.writeUInt64(fieldNumber: 5, value: entry.localTime)
                request.writeString(fieldNumber: 6, value: entry.path)
                request.writeUInt32(fieldNumber: 7, value: 0xffff_ffff)
                request.writeUInt32(fieldNumber: 9, value: session.cellID)
                request.writeUInt64(fieldNumber: 13, value: batch)
                let response = try SteamCloudUploadBlock.parse(try await session.callServiceMethod(
                    method: .cloudClientBeginFileUpload, body: request.data, timeout: 30))
                guard !response.encrypt, !response.blocks.isEmpty else { throw SteamFileError.invalid("Unsupported Steam save upload.") }
                try requireDirection(game.id, account: account, upload: true, resetID: resetID)
                if let sendUpload { try await sendUpload(bytes, response.blocks) }
                else {
                    try await SteamCloudTransfer.send(bytes, blocks: response.blocks, beforeBlock: {
                        try await self.requireDirection(game.id, account: account, upload: true, resetID: resetID)
                    })
                }
                try requireDirection(game.id, account: account, upload: true, resetID: resetID)
                var commit = ProtobufEncoder()
                commit.writeBool(fieldNumber: 1, value: true)
                commit.writeUInt32(fieldNumber: 2, value: UInt32(game.id))
                commit.writeBytes(fieldNumber: 3, value: sha)
                commit.writeString(fieldNumber: 4, value: entry.path)
                var reply = ProtobufDecoder(try await session.callServiceMethod(method: .cloudClientCommitFileUpload, body: commit.data, timeout: 30))
                var accepted = false
                while let tag = try reply.readTag() {
                    if tag.fieldNumber == 1, tag.wireType == .varint { accepted = try reply.readVarint() != 0 }
                    else { try reply.skip(wireType: tag.wireType) }
                }
                guard accepted else { throw SteamFileError.invalid("Steam did not accept the save file.") }
            }
            try requireDirection(game.id, account: account, upload: true, resetID: resetID)
            try await complete(game.id, batch: batch, success: true)
        } catch {
            if session.steamID == account { try? await complete(game.id, batch: batch, success: false) }
            throw error
        }
    }
    private func complete(_ appID: Int, batch: UInt64, success: Bool) async throws {
        var request = ProtobufEncoder()
        request.writeUInt32(fieldNumber: 1, value: UInt32(appID))
        request.writeUInt64(fieldNumber: 2, value: batch)
        request.writeUInt32(fieldNumber: 3, value: success ? 1 : 2)
        _ = try await session.callServiceMethod(method: .cloudCompleteAppUploadBatch, body: request.data, timeout: 30)
    }
}
