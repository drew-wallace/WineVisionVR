// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 125hz
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation

// Where Madeira's own Steam downloads live, and how one is read and removed
// (docs/STEAM_LIBRARY.md). Foundation only, so tests/host/check-steam-library.py
// compiles this file as it is.
//
// A download goes into Madeira Dock's own Steam library folder,
// C:\Program Files (x86)\Steam\steamapps, as `common/<installdir>` plus Steam's
// `appmanifest_<appid>.acf` install record. That is exactly the layout
// Madeira Dock's discovery (MadeiraDock.games) reads and Valve's client, which
// Dock starts the game through, understands: a game is "installed" for Dock
// once its record says so, and the record is written last.

enum SteamInstallPaths {
    /// The library folder, relative to drive_c (the value `DockGame.library` has).
    static let libraryRelative = "Program Files (x86)/Steam/steamapps"

    static func steamApps(drive: URL) -> URL { drive.appendingPathComponent(libraryRelative, isDirectory: true) }
    static func common(drive: URL) -> URL { steamApps(drive: drive).appendingPathComponent("common", isDirectory: true) }

    /// Whether an install (its drive-relative library folder) is in the library
    /// Madeira downloads into, and so can be updated or removed here.
    static func isManaged(library: String) -> Bool {
        library.caseInsensitiveCompare(libraryRelative) == .orderedSame
    }
}

enum SteamInstallFiles {
    /// The `buildid` the install record of an app states, or nil when there is
    /// no readable record.
    static func buildID(appID: Int, steamApps: URL) -> Int? {
        guard let state = record(appID: appID, steamApps: steamApps) else { return nil }
        return state["buildid"]?.string.flatMap { Int($0) }
    }

    /// The install size the record states (`SizeOnDisk`, bytes), or nil.
    static func sizeOnDisk(appID: Int, steamApps: URL) -> Int64? {
        guard let state = record(appID: appID, steamApps: steamApps),
              let size = state["SizeOnDisk"]?.string.flatMap({ Int64($0) }), size > 0 else { return nil }
        return size
    }

    /// Removes an app's install: its folder under `common`, its record, its
    /// resume journal and the records of the apps that own its shared depots
    /// (those describe the same folder). Keep the main record until removal
    /// succeeds so a filesystem failure remains visible and can be retried.
    nonisolated static func delete(appID: Int, folderName: String, steamApps: URL) throws {
        let fm = FileManager.default
        guard appID > 0, folderName == safeFolderName(folderName),
              !folderName.contains("/"), !folderName.contains("\\") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let root = steamApps.resolvingSymlinksInPath().standardizedFileURL
        let common = root.appendingPathComponent("common", isDirectory: true)
        let folder = common.appendingPathComponent(folderName, isDirectory: true)
        let inventory = root.appendingPathComponent("winevision-manifests/\(appID).json")
        let journal = root.appendingPathComponent("downloading/\(appID)", isDirectory: true)
        // Reject aliases before deleting anything: following a link could
        // remove another game's files, even when its target is in this library.
        for url in [common, folder, inventory.deletingLastPathComponent(), journal.deletingLastPathComponent()] {
            guard url.resolvingSymlinksInPath().standardizedFileURL.path == url.standardizedFileURL.path else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        func removeIfPresent(_ url: URL) throws {
            do { try fm.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
        }
        let recordURL = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        var ownerRecords: [URL] = []
        if let state = record(appID: appID, steamApps: steamApps) {
            for (_, owner) in (state["SharedDepots"]?.fields ?? [:]).sorted(by: { $0.key < $1.key }).prefix(64) {
                guard let ownerID = owner.string.flatMap({ Int($0) }), ownerID > 0, ownerID != appID,
                      let ownerState = record(appID: ownerID, steamApps: steamApps),
                      let dir = ownerState["installdir"]?.string,
                      safeFolderName(dir).caseInsensitiveCompare(safeFolderName(folderName)) == .orderedSame
                else { continue }
                ownerRecords.append(steamApps.appendingPathComponent("appmanifest_\(ownerID).acf"))
            }
        }
        try removeIfPresent(folder)
        try removeIfPresent(inventory)
        try removeIfPresent(journal)
        for owner in ownerRecords { try removeIfPresent(owner) }
        try removeIfPresent(recordURL)
    }

    /// Validates a manifest path and folds directory spelling to the first
    /// one seen (case-insensitively). Returns nil for anything that could
    /// escape the install folder.
    nonisolated static func safeRelativePath(_ name: String, folded: inout [String: String]) -> String? {
        let parts = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= 64, name.utf8.count < 1024,
              !parts.contains(where: { $0 == "." || $0 == ".." || $0.contains(":") ||
                  $0.unicodeScalars.contains(where: { $0.value < 0x20 }) }) else { return nil }
        var built: [String] = []
        for (index, part) in parts.enumerated() {
            if index == parts.count - 1 { built.append(part); break }
            let key = (built + [part]).joined(separator: "/").lowercased()
            if let existing = folded[key] {
                built = existing.split(separator: "/").map(String.init)
            } else {
                built.append(part)
                folded[key] = built.joined(separator: "/")
            }
        }
        return built.joined(separator: "/")
    }

    /// Install folders come from app metadata; keep them to one safe component.
    nonisolated static func safeFolderName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
        guard !cleaned.isEmpty, cleaned != ".", cleaned != "..", !cleaned.contains(":"),
              !cleaned.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return "app" }
        return cleaned
    }

    /// The `AppState` block of `appmanifest_<appid>.acf` when the file is
    /// readable, bounded, and names this app.
    static func record(appID: Int, steamApps: URL) -> SteamValue? {
        let url = steamApps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let data = try? Data(contentsOf: url), data.count <= 1 << 20,
              var parser = try? SteamKeyValues(data), let root = try? parser.read(),
              let state = root["AppState"], state["appid"]?.string == String(appID) else { return nil }
        return state
    }
}

/// A successful metadata refresh can distinguish an old install from an
/// unchecked/offline game. Depot IDs also catch DLC and shared-content updates
/// that do not change the parent game's build number.
enum SteamUpdateStatus: Equatable, Sendable {
    case unknown, upToDate, available

    var label: String {
        switch self {
        case .unknown: "Updates not checked"
        case .upToDate: "Up to date"
        case .available: "Update available"
        }
    }

    static func inspect(_ info: SteamAppInfo, steamApps: URL) -> Self {
        guard let state = SteamInstallFiles.record(appID: Int(info.appID), steamApps: steamApps) else { return .unknown }
        guard (state["StateFlags"]?.string.flatMap(UInt32.init) ?? 0) & 4 != 0 else { return .available }
        if info.buildID > 0, state["buildid"]?.string != String(info.buildID) { return .available }
        let selected = info.installDepots()
        guard !selected.isEmpty else { return .unknown }
        for depot in selected {
            let id = String(depot.depotID)
            var installed = state["InstalledDepots"]?[id]?["manifest"]?.string
            if installed == nil, let owner = state["SharedDepots"]?[id]?.string.flatMap(Int.init),
               let ownerState = SteamInstallFiles.record(appID: owner, steamApps: steamApps),
               ownerState["installdir"]?.string == state["installdir"]?.string {
                installed = ownerState["InstalledDepots"]?[id]?["manifest"]?.string
            }
            if installed != depot.publicManifestID.map(String.init) { return .available }
        }
        return .upToDate
    }
}
