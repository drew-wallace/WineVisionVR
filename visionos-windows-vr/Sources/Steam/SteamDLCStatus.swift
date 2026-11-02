// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 WineVision VR contributors
// See third-party/steam-native/COPYING and LICENSE-EXCEPTION.md.
import Foundation

struct SteamDLCStatus: Identifiable, Sendable {
    let id: UInt32
    let name: String
    let ready: Bool
    let hasDepots: Bool

    static func inspect(info: SteamAppInfo, owned: [SteamAppInfo], drive: URL) -> [SteamDLCStatus] {
        let manifest = SteamInstallPaths.steamApps(drive: drive).appendingPathComponent("appmanifest_\(info.appID).acf")
        let data = try? Data(contentsOf: manifest)
        var parser = data.flatMap { try? SteamKeyValues($0) }
        let state = (try? parser?.read())?["AppState"]
        let installed = state?["InstalledDepots"]
        let complete = (state?["StateFlags"]?.string.flatMap(UInt32.init) ?? 0) & 4 != 0
        let depots = info.installDepots()
        let ids = Set(owned.filter { $0.parentID == info.appID }.map(\.appID))
            .union(info.depots.compactMap(\.dlcAppID).filter { info.ownedDLC.contains($0) })
        return ids.sorted().map { id in
            let selected = depots.filter { $0.dlcAppID == id }
            let ready = complete && selected.allSatisfy {
                installed?[String($0.depotID)]?["manifest"]?.string == $0.publicManifestID.map(String.init)
            }
            return SteamDLCStatus(id: id, name: owned.first(where: { $0.appID == id })?.name ?? "DLC \(id)",
                                  ready: ready, hasDepots: !selected.isEmpty)
        }
    }
}
