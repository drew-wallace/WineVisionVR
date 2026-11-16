// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 Jfishin, 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Derived from Jfishin's Madeira Steam client, used in Madeira with the
// author's permission (see docs/STEAM_SIGNIN.md, "Provenance"). Substantially
// rewritten by 125hz for the owned library and downloads (docs/STEAM_LIBRARY.md).

import Foundation
import zlib
import CommonCrypto

/// Progress for one application install, across all of its depots.
struct SteamDownloadProgress: Equatable, Sendable {
    enum Phase: String, Sendable { case preparing, downloading, finishing }
    var phase: Phase = .preparing
    /// Compressed bytes to fetch for the whole install (all selected depots).
    var totalBytes: UInt64 = 0
    /// Compressed bytes downloaded during this attempt.
    var doneBytes: UInt64 = 0
    /// Compressed transfer bytes avoided by verifying installed/resumed chunks.
    var reusedBytes: UInt64 = 0
    var bytesPerSecond: Double = 0

    var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : (phase == .preparing ? 0 : 1) }
}

/// Orchestrates downloading an owned application's Windows depots from the
/// Steam content network into a Steam library folder.
///
/// Follows Steam's content protocol: the account's depot key and the
/// manifest request code come from the CM connection, which issues them only
/// to an account that owns the depot; manifests and chunks come from content
/// servers over HTTPS. Nothing here alters the downloaded files.
///
/// Behaviour:
/// - All manifests are fetched first, so progress covers the whole install.
/// - Completed chunks are journaled per depot manifest; a cancelled, failed or
///   interrupted install resumes without re-fetching them.
/// - Files are sized to their manifest length, so an update that shrinks a
///   file cannot leave stale trailing bytes.
/// - Chunk writes happen on the download tasks with pwrite, never on the
///   main actor. System-managed background URLSession transfers can finish while
///   visionOS suspends the app; encrypted results wait for verification on wake.
/// - Manifest paths are validated to stay inside the install folder, and
///   directory names are folded case-insensitively (Windows semantics on a
///   case-sensitive iOS volume).
/// - Each chunk retries on other content servers before the install fails.
@MainActor
final class DepotDownloader {
    private let session: SteamCMSession
    private let transfers: SteamBackgroundTransfers
    private var depotKeys: [UInt32: Data] = [:]
    private var cdnAuthTokens: [String: String] = [:]  // "depot|host" -> "?auth=…" fragment
    private let maxConcurrentChunks = 8
    private let attemptsPerChunk = 5
    private let hostPoolSize = 6

    private nonisolated static let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config)
    }()

    /// Replaces the content server directory (host tests only): the servers
    /// to fetch from, as `https://host` or `http://host:port` URLs.
    var contentHosts: ((_ appID: UInt32) async throws -> [String])?

    init(session: SteamCMSession, transfers: SteamBackgroundTransfers = .shared) {
        self.session = session
        self.transfers = transfers
    }

    // MARK: - Public API

    /// Download an app into `steamApps/common/<installdir>` and write its
    /// appmanifest. Returns the install folder. Throws CancellationError when
    /// the calling task is cancelled; completed chunks stay journaled.
    func install(_ app: SteamAppInfo, steamApps: URL,
                 ownedDepots: @escaping () async -> Set<UInt32>? = { nil },
                 progress report: @escaping (SteamDownloadProgress) -> Void) async throws -> URL {
        let depots = app.installDepots()
        guard !depots.isEmpty else { throw SteamError.depotNotFound(app.appID) }
        // Before the key requests, so a refused depot still has its selection logged.
        SteamLog.event("[steam-depot] selection app=\(app.appID) build=\(app.buildID) \(app.depotSelectionSummary())")

        let localFolder = SteamInstallFiles.record(appID: Int(app.appID), steamApps: steamApps)?["installdir"]?.string
        let folderName = SteamInstallFiles.safeFolderName(localFolder ?? (app.installDir.isEmpty ? "app_\(app.appID)" : app.installDir))
        let installURL = steamApps.appendingPathComponent("common", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        let journalDir = steamApps.appendingPathComponent("downloading", isDirectory: true)
            .appendingPathComponent("\(app.appID)", isDirectory: true)
        let commonURL = steamApps.appendingPathComponent("common").resolvingSymlinksInPath().standardizedFileURL
        guard installURL.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path == commonURL.path else {
            throw SteamError.chunkDownloadFailed("The game folder points outside this Steam library.")
        }
        try FileManager.default.createDirectory(at: installURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: journalDir, withIntermediateDirectories: true)

        var state = SteamDownloadProgress()
        report(state)

        depotCache = steamApps.appendingPathComponent("depotcache", isDirectory: true)
        let hosts: [String]
        if let provider = contentHosts { hosts = try await provider(app.appID) } else { hosts = try await contentServers(appID: app.appID) }
        guard !hosts.isEmpty else { throw SteamError.chunkDownloadFailed("No content servers are available.") }

        // 1. Keys, manifests and per-host authorization for every depot.
        let health = ContentHostHealth()
        let pool = Array(hosts.prefix(hostPoolSize))
        var plans: [DepotPlan] = []
        var licenseSkipped: [UInt32] = []
        // The logged-on account, for the install record. Read while the session
        // is connected: it idles out during a long download.
        var accountID: UInt64 = 0
        for depot in depots {
            try Task.checkCancellation()
            guard let gid = depot.publicManifestID else { continue }
            let key: Data
            do {
                key = try await depotKey(depotID: depot.depotID, appID: depot.dlcAppID ?? app.appID)
            } catch SteamError.depotKeyNotFound(let refused) {
                // A depot Steam refuses AND the account's licenses do not
                // include is content this account does not own (another
                // edition, extra content): it is left out. Any other refusal
                // still fails.
                if depot.dlcAppID == nil, let owned = await ownedDepots(), !owned.isEmpty, !owned.contains(refused) {
                    licenseSkipped.append(refused)
                    continue
                }
                throw SteamError.depotKeyNotFound(refused)
            }
            if session.steamID != 0 { accountID = session.steamID }
            let contentAppID = !app.freeToDownload ? (depot.fromApp ?? app.appID) : app.appID
            let manifest = try await fetchManifest(depotID: depot.depotID, appID: contentAppID,
                                                   manifestGID: gid, key: key, hosts: hosts)
            var auth: [String: String] = [:]
            for host in pool {
                auth[host] = await cdnAuthFragment(depotID: depot.depotID, appID: contentAppID, host: host)
            }
            plans.append(DepotPlan(depotID: depot.depotID, manifestGID: gid, key: key, manifest: manifest,
                                   hosts: pool, auth: auth,
                                   declaredSize: depot.publicSizeBytes, health: health))
        }
        if !licenseSkipped.isEmpty {
            SteamLog.event("[steam-depot] license app=\(app.appID) skipped=\(licenseSkipped.map(String.init).joined(separator: ",")) kept=\(plans.map { String($0.depotID) }.joined(separator: ","))")
        }
        guard !plans.isEmpty else {
            if let refused = licenseSkipped.first { throw SteamError.depotKeyNotFound(refused) }
            throw SteamError.depotNotFound(app.appID)
        }

        // Keep an incomplete marker even if interrupted before the first chunk.
        try Data().write(to: journalDir.appendingPathComponent("install.journal"))
        let inventoryURL = steamApps.appendingPathComponent("winevision-manifests/\(app.appID).json")
        let previous = InstallInventory.load(inventoryURL, appID: app.appID, folder: folderName)
        // Verification and local chunk moves must finish before any network writes.
        let preparation = Task.detached(priority: .userInitiated) {
            try Self.prepare(plans: plans, installURL: installURL, journalDir: journalDir, previous: previous)
        }
        let prepared = try await withTaskCancellationHandler {
            try await preparation.value
        } onCancel: { preparation.cancel() }
        try Task.checkCancellation()
        state.totalBytes = prepared.totalBytes
        state.doneBytes = prepared.doneBytes
        state.reusedBytes = prepared.reusedBytes
        state.phase = .downloading
        report(state)
        SteamLog.event("[steam-depot] install begin app=\(app.appID) depots=\(plans.count) files=\(prepared.fileCount) reused-bytes=\(prepared.reusedBytes) download-bytes=\(prepared.totalBytes)")

        let remaining = prepared.remainingUncompressed
        if remaining > 0 {
            let values = try? installURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            let available = UInt64(max(0, values?.volumeAvailableCapacityForImportantUsage ?? Int64.max))
            if available < remaining { throw SteamError.insufficientDiskSpace(needed: remaining, available: available) }
        }

        // 3. Chunks.
        let started = Date()
        let resumedBytes = state.doneBytes
        var lastReport = Date.distantPast
        for (index, plan) in plans.enumerated() {
            let journal = try JournalWriter(url: prepared.journals[index])
            defer { journal.close() }
            let work = prepared.pending[index]
            let paths = prepared.paths[index]
            let maximum = maxConcurrentChunks, attempts = attemptsPerChunk
            let transfers = self.transfers
            try await withThrowingTaskGroup(of: (UInt64, UInt64).self) { group in
                var next = 0
                func enqueue() {
                    guard next < work.count else { return }
                    let item = work[next]; next += 1
                    let chunk = plan.manifest.files[item.file].chunks[item.chunk]
                    let path = paths[item.file]
                    group.addTask {
                        try await Self.fetchChunk(chunk, plan: plan, path: path, attempts: attempts, seed: item.file &+ item.chunk, transfers: transfers)
                        return (item.key, UInt64(chunk.compressedSize))
                    }
                }
                for _ in 0..<min(maximum, work.count) { enqueue() }
                for try await (key, bytes) in group {
                    journal.append(key)
                    state.doneBytes += bytes
                    let now = Date()
                    if now.timeIntervalSince(lastReport) >= 0.25 {
                        lastReport = now
                        let elapsed = now.timeIntervalSince(started)
                        if elapsed > 1 { state.bytesPerSecond = Double(state.doneBytes - resumedBytes) / elapsed }
                        report(state)
                    }
                    enqueue()
                }
            }
        }

        state.phase = .finishing
        report(state)
        // 4. Remove obsolete, unmodified depot files and save the chunk inventory.
        // The old appmanifest remains authoritative until all installation work succeeds.
        try Task.checkCancellation()
        let finishing = Task.detached(priority: .userInitiated) {
            try Self.cleanObsoleteFiles(previous: previous, current: plans.map(\.manifest), installURL: installURL)
            try FileManager.default.createDirectory(at: inventoryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(InstallInventory(appID: app.appID, folder: folderName, manifests: plans.map(\.manifest)))
                .write(to: inventoryURL, options: .atomic)
        }
        try await withTaskCancellationHandler { try await finishing.value } onCancel: { finishing.cancel() }
        try Task.checkCancellation()
        // Install record. Sizes come from the manifests; no tree walk.
        let installed = plans.map { plan in
            AppManifestWriter.InstalledDepot(depotID: Int(plan.depotID), manifestGID: plan.manifestGID,
                                             size: Int64(plan.manifest.totalUncompressedSize),
                                             dlcAppID: depots.first(where: { $0.depotID == plan.depotID })?.dlcAppID.map(Int.init))
        }
        // Depots taken from another app are that app's content. Valve's client
        // refuses a launch until the owner app has its own record, so both
        // records are written the way the client writes them.
        var owners: [UInt32: UInt32] = [:]
        for depot in depots { if let from = depot.fromApp, from != app.appID, depot.dlcAppID == nil { owners[depot.depotID] = from } }
        let own = installed.filter { owners[UInt32($0.depotID)] == nil }
        let shared = installed.filter { owners[UInt32($0.depotID)] != nil }
        // Files Valve's client must customize per user before they run, as
        // Windows-style install-relative paths for the record's CheckGuid block.
        let custom = plans.flatMap { plan in
            plan.manifest.files.filter { $0.flags & DepotManifest.customExecutableFlag != 0 && !$0.isDirectory }
                .map { $0.filename.replacingOccurrences(of: "/", with: "\\") }
        }
        if !custom.isEmpty { SteamLog.event("[steam-record] custom-executables app=\(app.appID) custom=\(custom.count)") }
        try AppManifestWriter.writeManifest(
            appID: app.appID, name: app.name, installDir: folderName, buildID: app.buildID,
            steamID: accountID, sizeOnDisk: prepared.totalUncompressed,
            steamAppsPath: steamApps.path, installedDepots: own,
            sharedDepots: shared.map { ($0.depotID, Int(owners[UInt32($0.depotID)]!)) },
            customExecutables: custom)
        if !shared.isEmpty {
            var written = 0, skipped = 0
            for ownerID in Set(owners.values).sorted() {
                let depots = shared.filter { owners[UInt32($0.depotID)] == ownerID }
                guard !depots.isEmpty else { continue }
                // Only when the owner installs to this same folder, where the files are.
                guard let owner = app.sharedOwners[ownerID],
                      SteamInstallFiles.safeFolderName(owner.installDir).caseInsensitiveCompare(folderName) == .orderedSame else {
                    skipped += 1; continue
                }
                try AppManifestWriter.mergeOwnerManifest(ownerAppID: ownerID, ownerName: owner.name, ownerBuildID: owner.buildID,
                                                         installDir: folderName,
                                                         steamID: accountID, steamAppsPath: steamApps.path,
                                                         depots: depots)
                written += 1
            }
            SteamLog.event("[steam-shared-record] app=\(app.appID) shared=\(shared.count) owners-written=\(written) owners-skipped=\(skipped)")
        }
        try FileManager.default.removeItem(at: journalDir)
        SteamLog.event("[steam-depot] install complete app=\(app.appID) bytes=\(prepared.totalUncompressed) seconds=\(Int(Date().timeIntervalSince(started)))")
        return installURL
    }

    /// Whether a previous attempt left resumable progress for this app.
    static func hasPartialDownload(appID: UInt32, steamApps: URL) -> Bool {
        let dir = steamApps.appendingPathComponent("downloading/\(appID)", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".journal") }
    }

    // MARK: - Plan

    struct DepotPlan: Sendable {
        let depotID: UInt32
        let manifestGID: UInt64
        let key: Data
        let manifest: DepotManifest
        let hosts: [String]
        let auth: [String: String]
        let declaredSize: UInt64
        let health: ContentHostHealth
    }

    struct WorkItem: Sendable {
        let file: Int
        let chunk: Int
        var key: UInt64 { UInt64(file) << 32 | UInt64(chunk) }
    }

    struct Prepared: Sendable {
        var paths: [[String]] = []       // per depot, per file: absolute path ("" = skipped)
        var pending: [[WorkItem]] = []   // per depot: chunks still to fetch
        var journals: [URL] = []
        var totalBytes: UInt64 = 0
        var doneBytes: UInt64 = 0
        var reusedBytes: UInt64 = 0
        var totalUncompressed: UInt64 = 0
        var remainingUncompressed: UInt64 = 0
        var fileCount = 0
    }

    nonisolated static func prepare(plans: [DepotPlan], installURL: URL, journalDir: URL, previous: [DepotManifest] = []) throws -> Prepared {
        let fm = FileManager.default
        var result = Prepared()
        var folded: [String: String] = [:]   // lowercased relative dir -> first spelling
        var diskNames: [String: [String: String]] = [:]
        let journalNames = Set(plans.map { "depot_\($0.depotID)_\($0.manifestGID).journal" }).union(["install.journal"])
        // A journal for an older manifest describes different file contents.
        for name in (try? fm.contentsOfDirectory(atPath: journalDir.path)) ?? [] where !journalNames.contains(name) {
            try? fm.removeItem(at: journalDir.appendingPathComponent(name))
        }
        let oldFiles = Dictionary(previous.flatMap(\.files).map { ($0.filename.replacingOccurrences(of: "\\", with: "/").lowercased(), $0) },
                                  uniquingKeysWith: { _, latest in latest })
        for plan in plans {
            try Task.checkCancellation()
            let journalURL = journalDir.appendingPathComponent("depot_\(plan.depotID)_\(plan.manifestGID).journal")
            var paths: [String] = []
            var pending: [WorkItem] = []
            paths.reserveCapacity(plan.manifest.files.count)
            for (fileIndex, file) in plan.manifest.files.enumerated() {
                // Symlinks (flag 0x200) have no Windows meaning here; skip them.
                guard file.flags & 0x200 == 0,
                      let relative = SteamInstallFiles.safeRelativePath(file.filename, folded: &folded) else {
                    if file.flags & 0x200 == 0 { SteamLog.trace("rejected manifest path in depot \(plan.depotID)") }
                    paths.append(""); continue
                }
                guard let url = installedURL(relative, root: installURL, names: &diskNames) else {
                    throw SteamError.chunkDownloadFailed("A game file points outside its install folder.")
                }
                if file.isDirectory {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    paths.append(""); continue
                }
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                var before = stat()
                let hadContent = stat(url.path, &before) == 0 && before.st_size > 0
                let reused = try reuseChunks(file, previous: oldFiles[relative.lowercased()], path: url.path,
                                             staging: journalDir.appendingPathComponent("reuse.tmp"))
                paths.append(url.path)
                result.fileCount += 1
                result.totalUncompressed += file.size
                var pendingBytes: UInt64 = 0
                for (chunkIndex, chunk) in file.chunks.enumerated() {
                    let item = WorkItem(file: fileIndex, chunk: chunkIndex)
                    if reused.contains(chunkIndex) {
                        result.reusedBytes += UInt64(chunk.compressedSize)
                    } else {
                        result.totalBytes += UInt64(chunk.compressedSize)
                        pending.append(item)
                        pendingBytes += UInt64(chunk.uncompressedSize)
                    }
                }
                // Space already allocated to an existing file is reused; only
                // its growth needs new space (sparse new files need all of it).
                let beforeSize = hadContent ? UInt64(before.st_size) : 0
                result.remainingUncompressed += hadContent
                    ? (file.size > beforeSize ? file.size - beforeSize : 0) : pendingBytes
            }
            result.paths.append(paths)
            result.pending.append(pending)
            result.journals.append(journalURL)
        }
        return result
    }

    /// Create or resize a file to its manifest length. Existing bytes below
    /// that length are kept so resumed and updated installs reuse them.
    private nonisolated static func sizeFile(_ path: String, to size: UInt64) throws {
        let fd = open(path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else { throw SteamError.chunkDownloadFailed("Cannot create a game file (errno \(errno)).") }
        defer { close(fd) }
        var info = stat()
        if fstat(fd, &info) == 0, UInt64(info.st_size) == size { return }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw SteamError.chunkDownloadFailed("Cannot size a game file (errno \(errno)).")
        }
    }

    // MARK: - Chunks

    /// A chunk's ID is the SHA-1 of its uncompressed bytes. When a file
    /// already had content (an update, or a resume without a journal), bytes
    /// that already match are kept instead of downloaded again.
    private nonisolated static func verifiedChunk(_ chunk: DepotManifest.ChunkEntry, path: String) -> Data? {
        let length = Int(chunk.uncompressedSize)
        guard chunk.sha.count == Int(CC_SHA1_DIGEST_LENGTH), length > 0,
              length <= ContentDecryptor.maximumChunkBytes, chunk.offset <= UInt64(Int64.max) - UInt64(length) else { return nil }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(chunk.offset)) }
        guard read == length else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        _ = CC_SHA1(buffer, CC_LONG(length), &digest)
        return Data(digest) == chunk.sha ? Data(buffer) : nil
    }

    /// Stage moved chunks before resizing/writing: an insertion, reorder or
    /// shrink must never overwrite a source chunk that will be reused later.
    private nonisolated static func reuseChunks(_ file: DepotManifest.FileEntry, previous: DepotManifest.FileEntry?,
                                                path: String, staging: URL) throws -> Set<Int> {
        guard file.size <= UInt64(Int64.max) else { throw SteamError.manifestFetchFailed("Game file is too large.") }
        var end: UInt64 = 0
        for chunk in file.chunks.sorted(by: { $0.offset < $1.offset }) {
            guard chunk.offset >= end, chunk.offset <= file.size,
                  UInt64(chunk.uncompressedSize) <= file.size - chunk.offset else {
                throw SteamError.manifestFetchFailed("Invalid game chunk range.")
            }
            end = chunk.offset + UInt64(chunk.uncompressedSize)
        }
        let candidates = Dictionary(grouping: previous?.chunks ?? [], by: \.sha)
        var reused = Set<Int>(), moved: [Int] = []
        defer { try? FileManager.default.removeItem(at: staging) }
        for (index, chunk) in file.chunks.enumerated() {
            try Task.checkCancellation()
            if verifiedChunk(chunk, path: path) != nil { reused.insert(index); continue }
            for old in candidates[chunk.sha] ?? [] where old.uncompressedSize == chunk.uncompressedSize && old.offset != chunk.offset {
                if let bytes = verifiedChunk(old, path: path) {
                    if moved.isEmpty { try Data().write(to: staging) }
                    try write(bytes, to: staging.path, offset: chunk.offset)
                    moved.append(index)
                    break
                }
            }
        }
        try sizeFile(path, to: file.size)
        for index in moved {
            try Task.checkCancellation()
            let chunk = file.chunks[index]
            guard let bytes = verifiedChunk(chunk, path: staging.path) else { throw SteamError.checksumMismatch }
            try write(bytes, to: path, offset: chunk.offset)
            reused.insert(index)
        }
        return reused
    }

    private struct InstallInventory: Codable {
        let appID: UInt32
        let folder: String
        let manifests: [DepotManifest]

        static func load(_ url: URL, appID: UInt32, folder: String) -> [DepotManifest] {
            guard let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode(Self.self, from: data),
                  saved.appID == appID, saved.folder == folder else { return [] }
            return saved.manifests
        }
    }

    /// Steam paths have Windows casing semantics even on a case-sensitive
    /// volume. Reuse each existing component's spelling, including filenames.
    private nonisolated static func installedURL(_ relative: String, root: URL,
                                                  names: inout [String: [String: String]]) -> URL? {
        var url = root.resolvingSymlinksInPath().standardizedFileURL
        for component in relative.split(separator: "/").map(String.init) {
            let parent = url.path
            if names[parent] == nil {
                names[parent] = Dictionary(((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).sorted()
                    .map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
            }
            let spelling = names[parent]?[component.lowercased()] ?? component
            names[parent]?[component.lowercased()] = spelling
            url.appendPathComponent(spelling)
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), url.resolvingSymlinksInPath().standardizedFileURL.path == url.path else { return nil }
        return url
    }

    /// Only delete files present in the last successful inventory and still
    /// byte-for-byte original. User data and modified/added files are retained.
    nonisolated static func cleanObsoleteFiles(previous: [DepotManifest], current: [DepotManifest], installURL: URL) throws {
        let fm = FileManager.default
        let retained = Set(current.flatMap(\.files).map { $0.filename.replacingOccurrences(of: "\\", with: "/").lowercased() })
        var folded: [String: String] = [:]
        var diskNames: [String: [String: String]] = [:]
        for file in previous.flatMap(\.files) where !file.isDirectory && file.flags & 0x200 == 0 {
            try Task.checkCancellation()
            guard let relative = SteamInstallFiles.safeRelativePath(file.filename, folded: &folded),
                  !retained.contains(relative.lowercased()), let url = installedURL(relative, root: installURL, names: &diskNames),
                  let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.uint64Value == file.size else { continue }
            let chunks = file.chunks.sorted { $0.offset < $1.offset }
            var end: UInt64 = 0
            var original = true
            for chunk in chunks {
                guard chunk.offset == end, verifiedChunk(chunk, path: url.path) != nil else { original = false; break }
                end += UInt64(chunk.uncompressedSize)
            }
            guard original, end == file.size else { continue }
            try fm.removeItem(at: url)
            var parent = url.deletingLastPathComponent()
            let base = installURL.resolvingSymlinksInPath().standardizedFileURL.path
            while parent.path.hasPrefix(base + "/"), (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try fm.removeItem(at: parent)
                parent.deleteLastPathComponent()
            }
        }
        for directory in previous.flatMap(\.files).filter({ $0.isDirectory && $0.flags & 0x200 == 0 })
            .sorted(by: { $0.filename.count > $1.filename.count }) {
            try Task.checkCancellation()
            guard let relative = SteamInstallFiles.safeRelativePath(directory.filename, folded: &folded),
                  !retained.contains(relative.lowercased()),
                  let url = installedURL(relative, root: installURL, names: &diskNames),
                  (try? fm.contentsOfDirectory(atPath: url.path))?.isEmpty == true else { continue }
            try fm.removeItem(at: url)
        }
    }

    private nonisolated static func fetchChunk(_ chunk: DepotManifest.ChunkEntry, plan: DepotPlan,
                                               path: String, attempts: Int, seed: Int, transfers: SteamBackgroundTransfers) async throws {
        var lastError: Error = SteamError.chunkDownloadFailed("No content server responded.")
        for attempt in 0..<max(1, attempts) {
            try Task.checkCancellation()
            // Healthy servers first, starting from a per-chunk offset.
            let order = plan.health.order(plan.hosts, seed: seed)
            let host = order[attempt % order.count]
            let url = "\(host)/depot/\(plan.depotID)/chunk/\(chunk.shaHex)\(plan.auth[host] ?? "")"
            do {
                guard let requestURL = URL(string: url) else {
                    throw SteamError.chunkDownloadFailed("Invalid content URL.")
                }
                let encrypted = try await transfers.data(for: requestURL)
                // Background results are retained on disk until verification and
                // writing have run. Never reuse corrupt data on the next host retry.
                defer { transfers.removeCachedData(for: requestURL) }
                let data = try ContentDecryptor.processChunk(encryptedData: encrypted, depotKey: plan.key,
                                                             expectedCRC: chunk.crc,
                                                             expectedSize: Int(chunk.uncompressedSize))
                guard data.count == Int(chunk.uncompressedSize) else { throw SteamError.checksumMismatch }
                try write(data, to: path, offset: chunk.offset)
                plan.health.recordSuccess(host)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
                plan.health.recordFailure(host, reason: failureReason(error))
                SteamLog.trace("chunk attempt \(attempt + 1) failed: \(failureReason(error))")
                if attempt + 1 < attempts { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 400_000_000) }
            }
        }
        throw lastError
    }

    private nonisolated static func failureReason(_ error: Error) -> String {
        if let url = error as? URLError { return "url\(url.code.rawValue)" }
        if case SteamError.chunkDecodeFailed(let format) = error { return "decode-\(format)" }
        if case SteamError.checksumMismatch = error { return "checksum" }
        return "other"
    }

    private nonisolated static func write(_ data: Data, to path: String, offset: UInt64) throws {
        let fd = open(path, O_WRONLY)
        guard fd >= 0 else { throw SteamError.chunkDownloadFailed("Cannot open a game file (errno \(errno)).") }
        defer { close(fd) }
        try data.withUnsafeBytes { raw in
            var written = 0
            while written < raw.count {
                let n = pwrite(fd, raw.baseAddress! + written, raw.count - written, off_t(offset) + off_t(written))
                guard n > 0 else { throw SteamError.chunkDownloadFailed("Cannot write a game file (errno \(errno)).") }
                written += n
            }
        }
    }

    private nonisolated static func download(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw SteamError.chunkDownloadFailed("Invalid content URL.") }
        let (data, response) = try await http.data(from: url)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw SteamError.chunkDownloadFailed("Content server returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return data
    }

    // MARK: - Manifest

    private func fetchManifest(depotID: UInt32, appID: UInt32, manifestGID: UInt64,
                               key: Data, hosts: [String]) async throws -> DepotManifest {
        let requestCode = try await manifestRequestCode(depotID: depotID, appID: appID, manifestGID: manifestGID)
        var lastError: Error = SteamError.manifestFetchFailed("No content server returned the manifest.")
        for host in hosts.prefix(6) {
            try Task.checkCancellation()
            let auth = await cdnAuthFragment(depotID: depotID, appID: appID, host: host)
            let code = requestCode == 0 ? "" : "/\(requestCode)"
            do {
                let raw = try await Self.download("\(host)/depot/\(depotID)/manifest/\(manifestGID)/5\(code)\(auth)")
                let cache = depotCache
                return try await Task.detached(priority: .userInitiated) {
                    let (manifest, payload) = try Self.parseManifestKeepingPayload(raw, depotID: depotID, manifestGID: manifestGID, key: key)
                    // Valve's client reads a depot's manifest from steamapps/depotcache
                    // when it prepares a per-user custom executable. Keep it for such depots.
                    if let cache, manifest.files.contains(where: { $0.flags & DepotManifest.customExecutableFlag != 0 }) {
                        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                        let file = cache.appendingPathComponent("\(depotID)_\(manifestGID).manifest")
                        let existing = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
                        if existing != payload.count { try? payload.write(to: file, options: .atomic) }
                    }
                    return manifest
                }.value
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                SteamLog.trace("manifest from a content server failed: \(error.localizedDescription)")
            }
        }
        throw lastError
    }

    private nonisolated static func parseManifest(_ raw: Data, depotID: UInt32, manifestGID: UInt64, key: Data) throws -> DepotManifest {
        try parseManifestKeepingPayload(raw, depotID: depotID, manifestGID: manifestGID, key: key).0
    }

    /// The manifest and the binary manifest bytes it was parsed from (unzipped, decrypted).
    private nonisolated static func parseManifestKeepingPayload(_ raw: Data, depotID: UInt32, manifestGID: UInt64,
                                                                key: Data) throws -> (DepotManifest, Data) {
        // Content servers deliver the manifest as a single-entry ZIP.
        let payload = raw.starts(with: [0x50, 0x4B]) ? try unzipSingleFile(raw) : raw
        if let plain = try? DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: payload, depotKey: key),
           !plain.files.isEmpty {
            return (plain, payload)
        }
        // Older depots encrypt the whole manifest with the depot key.
        let decrypted = try ContentDecryptor.decryptChunk(encryptedData: payload, depotKey: key)
        let inflated = (try? ContentDecryptor.decompressChunk(compressedData: decrypted, expectedSize: 0)) ?? decrypted
        return (try DepotManifest.parse(depotID: depotID, manifestGID: manifestGID, data: inflated, depotKey: key), inflated)
    }

    /// steamapps/depotcache while an install runs.
    private var depotCache: URL?

    /// Extract the single deflated entry from a manifest ZIP. No zip lib needed —
    /// parse the local file header and inflate the raw deflate stream.
    nonisolated static func unzipSingleFile(_ data: Data) throws -> Data {
        let data = Data(data)  // zero-based indices
        guard data.count > 30,
              data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 else {
            throw SteamError.manifestFetchFailed("Not a zip")
        }
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { Int(data[o]) | Int(data[o+1]) << 8 | Int(data[o+2]) << 16 | Int(data[o+3]) << 24 }
        let method = u16(8)
        let compSize = u32(18)
        let uncompSize = u32(22)
        let nameLen = u16(26), extraLen = u16(28)
        let start = 30 + nameLen + extraLen
        guard start + compSize <= data.count, method == 0 || method == 8,
              uncompSize <= ContentDecryptor.maximumChunkBytes * 4 else {
            throw SteamError.manifestFetchFailed("Bad zip entry (method \(method))")
        }
        let entry = data.subdata(in: start..<(start + compSize))
        if method == 0 { return entry }

        // Zip stores raw deflate — inflate with zlib, negative windowBits
        var strm = z_stream()
        let cap = max(uncompSize, 1024)
        var out = Data(count: cap)
        var n = -1
        entry.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                strm.next_in = UnsafeMutablePointer(mutating: src.bindMemory(to: UInt8.self).baseAddress)
                strm.avail_in = UInt32(entry.count)
                strm.next_out = dst.bindMemory(to: UInt8.self).baseAddress
                strm.avail_out = UInt32(cap)
                guard inflateInit2_(&strm, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return }
                let r = inflate(&strm, Z_FINISH)
                inflateEnd(&strm)
                if r == Z_STREAM_END { n = Int(strm.total_out) }
            }
        }
        guard n >= 0 else { throw SteamError.decompressionFailed }
        out.count = n
        return out
    }

    // MARK: - Depot Key

    private func depotKey(depotID: UInt32, appID: UInt32) async throws -> Data {
        if let cached = depotKeys[depotID] { return cached }
        try await session.ensureConnected()

        var request = CMsgClientGetDepotDecryptionKey()
        request.depotID = depotID
        request.appID = appID

        let response = try await session.sendAndWait(
            eMsg: .clientGetDepotDecryptionKey,
            body: request.serialize(),
            responseEMsg: .clientGetDepotDecryptionKeyResponse,
            timeout: 15
        )

        let keyResponse = try CMsgClientGetDepotDecryptionKeyResponse.deserialize(from: response.body)
        // Steam only issues keys for depots this account owns.
        guard EResult(rawValue: UInt32(keyResponse.eresult))?.isSuccess == true,
              keyResponse.depotEncryptionKey.count == 32 else {
            SteamLog.event("[steam-depot] depot-key refused app=\(appID) depot=\(depotID) eresult=\(keyResponse.eresult)")
            throw SteamError.depotKeyNotFound(depotID)
        }

        depotKeys[depotID] = keyResponse.depotEncryptionKey
        return keyResponse.depotEncryptionKey
    }

    // MARK: - Manifest Request Code

    private func manifestRequestCode(depotID: UInt32, appID: UInt32, manifestGID: UInt64) async throws -> UInt64 {
        try await session.ensureConnected()
        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: appID)
        encoder.writeUInt32(fieldNumber: 2, value: depotID)
        encoder.writeUInt64(fieldNumber: 3, value: manifestGID)

        let responseData = try await session.callServiceMethod(
            method: .getManifestRequestCode,
            body: encoder.data,
            timeout: 15
        )

        var decoder = ProtobufDecoder(responseData)
        while let tag = try decoder.readTag() {
            if tag.fieldNumber == 1 {
                // manifest_request_code is fixed64 on the wire
                return tag.wireType == .fixed64 ? try decoder.readFixed64() : try decoder.readVarint()
            }
            try decoder.skip(wireType: tag.wireType)
        }

        return 0 // No request code needed (older depots)
    }

    // MARK: - CDN Discovery + Auth

    /// Content server discovery via the public Web API
    /// (IContentServerDirectoryService/GetServersForSteamPipe). No account
    /// token is attached; the directory does not require one.
    enum ServerEligibility: Equatable { case usable, noHTTPS, other }

    /// Directory fields as served by GetServersForSteamPipe: https_support
    /// ("mandatory", "optional", "unavailable"), use_as_proxy, and an optional
    /// allowed_app_ids restriction.
    nonisolated static func serverEligibility(_ server: [String: Any], appID: UInt32) -> ServerEligibility {
        if let https = (server["https_support"] as? String)?.lowercased(), https != "mandatory", https != "optional" {
            return .noHTTPS
        }
        if (server["use_as_proxy"] as? Bool) == true || (server["use_as_proxy"] as? NSNumber)?.boolValue == true {
            return .other
        }
        if let allowed = server["allowed_app_ids"] as? [Any], !allowed.isEmpty,
           !allowed.contains(where: { ($0 as? NSNumber)?.uint32Value == appID || ($0 as? String) == String(appID) }) {
            return .other
        }
        return .usable
    }

    private func contentServers(appID: UInt32) async throws -> [String] {
        var hosts: [String] = []
        do {
            guard let url = URL(string: "https://api.steampowered.com/IContentServerDirectoryService/GetServersForSteamPipe/v1/?cell_id=\(session.cellID)&max_servers=20") else {
                throw SteamError.chunkDownloadFailed("Bad content directory URL")
            }
            let (data, response) = try await Self.http.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw SteamError.chunkDownloadFailed("Content directory HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let resp = json["response"] as? [String: Any],
                  let servers = resp["servers"] as? [[String: Any]] else {
                throw SteamError.chunkDownloadFailed("Content directory returned unexpected data")
            }
            // In the directory's order. The directory marks some CDN servers
            // https_support "unavailable"; requesting them over HTTPS fails the
            // TLS handshake (NSURLError -1200). Such servers, proxy-only entries
            // and servers restricted to other apps are skipped.
            var skippedHTTP = 0, skippedOther = 0
            for server in servers {
                let host = (server["vhost"] as? String) ?? (server["host"] as? String) ?? ""
                guard Self.usableContentHost(host) else { skippedOther += 1; continue }
                switch Self.serverEligibility(server, appID: appID) {
                case .usable: break
                case .noHTTPS: skippedHTTP += 1; continue
                case .other: skippedOther += 1; continue
                }
                let entry = "https://\(host)"
                if !hosts.contains(entry) { hosts.append(entry) }
            }
            SteamLog.event("[steam-cdn] offered=\(servers.count) usable=\(hosts.count) skipped-no-https=\(skippedHTTP) skipped-other=\(skippedOther)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            SteamLog.trace("content directory failed: \(error.localizedDescription)")
        }
        let fallback = "https://steampipe.akamaized.net"
        if !hosts.contains(fallback) { hosts.append(fallback) }
        return hosts
    }

    nonisolated static func usableContentHost(_ host: String) -> Bool {
        guard host.contains("."), !host.contains(" "), !host.contains("/"), !host.contains("*"),
              !host.contains("lancache"), !host.contains(":") else { return false }
        return host.hasSuffix(".steamcontent.com") || host.hasSuffix(".akamaized.net") ||
            host.hasSuffix(".steampipe.steamcontent.com") || host.hasSuffix(".steamstatic.com")
    }

    /// Unified-service GetCDNAuthToken → "?auth=…" query fragment for this
    /// depot on this host. An empty token is normal outside regional edge
    /// networks. Cached per depot and host.
    private func cdnAuthFragment(depotID: UInt32, appID: UInt32, host: String) async -> String {
        let cacheKey = "\(depotID)|\(host)"
        if let cached = cdnAuthTokens[cacheKey] { return cached }

        // host_name must be the bare hostname, not the https:// URL
        let bareHost = URL(string: host)?.host ?? host

        var encoder = ProtobufEncoder()
        encoder.writeUInt32(fieldNumber: 1, value: depotID)  // depot_id = 1
        encoder.writeString(fieldNumber: 2, value: bareHost) // host_name = 2
        encoder.writeUInt32(fieldNumber: 3, value: appID)    // app_id = 3

        do {
            try await session.ensureConnected()
            let responseData = try await session.callServiceMethod(
                method: .getCDNAuthToken,
                body: encoder.data,
                timeout: 10
            )
            var decoder = ProtobufDecoder(responseData)
            var token = ""
            while let tag = try decoder.readTag() {
                if tag.fieldNumber == 1 { token = try decoder.readString() } else { try decoder.skip(wireType: tag.wireType) }
            }
            let fragment = token.isEmpty ? "" : (token.hasPrefix("?") || token.hasPrefix("&") ? token : "?auth=\(token)")
            cdnAuthTokens[cacheKey] = fragment
            return fragment
        } catch {
            SteamLog.trace("content authorization request failed; continuing without a token")
            cdnAuthTokens[cacheKey] = ""
            return ""
        }
    }
}

/// Per-install content-server health. Chunks start on different servers
/// (spreading load) and servers that keep failing move to the back of every
/// chunk's rotation, instead of each chunk rediscovering a bad server.
final class ContentHostHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String: Int] = [:]
    private var reported = 0

    func order(_ hosts: [String], seed: Int) -> [String] {
        guard !hosts.isEmpty else { return hosts }
        let rotated = (0..<hosts.count).map { hosts[($0 + seed) % hosts.count] }
        lock.lock(); let counts = failures; lock.unlock()
        return rotated.enumerated()
            .sorted { ((counts[$0.element] ?? 0), $0.offset) < ((counts[$1.element] ?? 0), $1.offset) }
            .map(\.element)
    }

    func recordFailure(_ host: String, reason: String) {
        lock.lock()
        failures[host, default: 0] += 1
        let report = failures[host] == 3 && reported < 8
        if report { reported += 1 }
        lock.unlock()
        if report {
            let server = host.replacingOccurrences(of: "https://", with: "")
            DispatchQueue.main.async { SteamLog.event("[steam-cdn] host demoted host=\(server) reason=\(reason)") }
        }
    }

    func recordSuccess(_ host: String) {
        lock.lock()
        if let count = failures[host], count > 0 { failures[host] = count - 1 }
        lock.unlock()
    }
}

/// Append-only record of completed chunks for one depot manifest. Lines are
/// hexadecimal work-item keys. A lost tail only causes those chunks to be
/// fetched again.
final class JournalWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var pending = 0

    init(url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forUpdating: url)
        // A previous attempt killed mid-write can leave a partial last line;
        // start on a fresh line so the first new key is not glued onto it.
        let end = handle.seekToEndOfFile()
        if end > 0 {
            handle.seek(toFileOffset: end - 1)
            if handle.readData(ofLength: 1) != Data([0x0A]) { buffer = "\n" }
            handle.seekToEndOfFile()
        }
    }

    func append(_ key: UInt64) {
        buffer += String(key, radix: 16) + "\n"
        pending += 1
        if pending >= 64 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        handle.write(Data(buffer.utf8))
        buffer = ""; pending = 0
    }

    func close() {
        flush()
        try? handle.close()
    }

    static func load(_ url: URL) -> Set<UInt64> {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var keys = Set<UInt64>()
        for line in text.split(separator: "\n") { if let key = UInt64(line, radix: 16) { keys.insert(key) } }
        return keys
    }
}
