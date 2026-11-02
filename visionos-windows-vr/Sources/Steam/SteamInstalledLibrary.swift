// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
import Foundation

/// The installed catalog belongs to disk, not to a successful Steam response.
/// Server metadata enriches cards without adding/removing local installations.
enum SteamInstalledLibrary {
    static func games(records: [DockGame], metadata: [SteamOwnedGame]) -> [SteamOwnedGame] {
        let details = Dictionary(metadata.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var seen = Set<Int>()
        return records.filter { $0.installed && seen.insert($0.id).inserted }.map { record in
            if var game = details[record.id] {
                game.installDir = record.installDir
                return game
            }
            var info = SteamAppInfo(appID: UInt32(record.id))
            info.name = record.name
            info.installDir = record.installDir
            return SteamOwnedGame(info)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
