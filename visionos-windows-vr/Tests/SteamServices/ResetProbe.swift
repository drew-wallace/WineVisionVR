import Foundation

@MainActor
func checkLocalSaveReset(root: URL) async throws {
    let fm = FileManager.default
    let drive = root.appendingPathComponent("drive_c")
    let state = root.appendingPathComponent("state")
    let steam = FakeSteam()
    var idle = true
    let service = SteamGameServices(session: steam, drive: drive, support: state, idle: { idle })
    let game = DockGame(id: 10, name: "Fixture", installDir: "Fixture", library: SteamRuntimeFiles.relativeRoot + "/steamapps")
    var info = SteamAppInfo(appID: 10)
    info.saveFiles = [.init(root: "WinAppDataRoaming", path: "Fixture", pattern: "*.sav", recursive: true, platforms: ["windows"])]
    let remote = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/userdata/\(steam.steamID & 0xffff_ffff)/10/remote")
    let apiSave = remote.appendingPathComponent("progress.save")
    let cache = remote.deletingLastPathComponent().appendingPathComponent("remotecache.vdf")
    let local = drive.appendingPathComponent("users/test/AppData/Roaming/Fixture/progress.sav")
    let older = drive.appendingPathComponent("users/old/AppData/Roaming/Fixture/nested/old.sav")
    let unrelated = drive.appendingPathComponent("users/test/AppData/Roaming/OtherGame/progress.sav")
    let dlc = drive.appendingPathComponent(game.library + "/common/Fixture/expansion.pak")
    let logFile = local.deletingLastPathComponent().appendingPathComponent("game.log")
    func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    for file in [apiSave, cache, local, older, unrelated, dlc, logFile] { try write("keep until confirmed", file) }
    steam.remote = ["progress.save": Data("actual cloud save".utf8)]
    let originalCloud = steam.remote
    try service.setPermissions(10, account: steam.steamID, upload: true, download: true)
    let count = try await service.resetLocalSaves(game: game, info: info)
    expect(count == 4)
    for file in [apiSave, cache, local, older] { expect(!fm.fileExists(atPath: file.path)) }
    for file in [unrelated, dlc, logFile] { expect(fm.fileExists(atPath: file.path)) }
    expect(steam.remote == originalCloud && steam.batches == 0 && steam.commits == 0)
    expect(steam.methods.allSatisfy { $0 == .cloudGetAppFileChangelist })
    let persisted = SteamGameServices(session: steam, drive: drive, support: state, idle: { true })
    expect(try persisted.permissions(10, account: steam.steamID) == .init(upload: false, download: false))
    expect(try persisted.pendingApps().isEmpty)
    expect(try !persisted.record(10, account: steam.steamID).restored)
    let config = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/userdata/\(steam.steamID & 0xffff_ffff)/config/localconfig.vdf")
    var parser = try SteamKeyValues(Data(contentsOf: config))
    let settings = try parser.read()
    expect(settings["userlocalconfigstore"]?["software"]?["valve"]?["steam"]?["apps"]?["10"]?["cloudenabled"]?.string == "0")
    log("PASS reset disables both directions durably, clears only selected local saves/cache, preserves cloud and DLC")

    try write("offline progress", apiSave)
    _ = try await service.sync(game: game, info: info)
    expect(try Data(contentsOf: apiSave) == Data("offline progress".utf8))
    try service.setPermissions(10, account: steam.steamID, upload: true)
    do { _ = try await service.sync(game: game, info: info); fatalError("upload enabled before safe restore") } catch {}
    expect(steam.remote == originalCloud && steam.commits == 0)
    try service.setPermissions(10, account: steam.steamID, download: true)
    try service.prepareClientSettings(10)
    var heldParser = try SteamKeyValues(Data(contentsOf: config))
    let heldSettings = try heldParser.read()
    expect(heldSettings["userlocalconfigstore"]?["software"]?["valve"]?["steam"]?["apps"]?["10"]?["cloudenabled"]?.string == "0")
    try service.setPermissions(10, account: steam.steamID, upload: false, download: true)
    service.downloadFile = { _, entry in steam.remote[entry.path]! }
    _ = try await service.sync(game: game, info: info, preferCloud: true)
    expect(try Data(contentsOf: apiSave) == originalCloud["progress.save"])
    expect(steam.commits == 0)
    log("PASS reset cannot upload fresh local progress before an explicit cloud restore; downloads can restore safely")

    steam.failListing = true
    do { _ = try await service.resetLocalSaves(game: game, info: info); fatalError("failed listing reset accepted") } catch {}
    expect(fm.fileExists(atPath: apiSave.path))
    expect(try service.permissions(10, account: steam.steamID) == .init(upload: false, download: false))
    steam.failListing = false
    idle = false
    do { _ = try await service.resetLocalSaves(game: game, info: info); fatalError("reset with Wine running") } catch {}
    expect(fm.fileExists(atPath: apiSave.path))
    idle = true
    log("PASS failed cloud listing and running game preserve local files")

    let outside = root.appendingPathComponent("outside")
    try write("other game", outside.appendingPathComponent("outside.sav"))
    let link = remote.appendingPathComponent("linked")
    try fm.createSymbolicLink(at: link, withDestinationURL: outside)
    do { _ = try await service.resetLocalSaves(game: game, info: info); fatalError("symlink reset accepted") } catch {}
    expect(fm.fileExists(atPath: apiSave.path) && fm.fileExists(atPath: outside.appendingPathComponent("outside.sav").path))
    try fm.removeItem(at: link)
    steam.remote["../escape.sav"] = Data("unsafe cloud path".utf8)
    do { _ = try await service.resetLocalSaves(game: game, info: info); fatalError("unsafe mapped save accepted") } catch {}
    expect(fm.fileExists(atPath: apiSave.path))
    steam.remote = originalCloud
    log("PASS reset preflights all paths and refuses traversal or symlinks without partial deletion")

    // A pre-reset download must not put a stale save back, even if permissions
    // are re-enabled while its transport is suspended.
    try service.setPermissions(10, account: steam.steamID, upload: false, download: true)
    service.downloadFile = { _, entry in
        let bytes = steam.remote[entry.path]!
        _ = try await service.resetLocalSaves(game: game, info: info)
        try service.setPermissions(10, account: steam.steamID, upload: false, download: true)
        return bytes
    }
    do { _ = try await service.sync(game: game, info: info); fatalError("stale download survived reset") } catch {}
    expect(!fm.fileExists(atPath: apiSave.path))
    expect(try service.record(10, account: steam.steamID).requiresCloudRestore == true)
    service.downloadFile = { _, entry in steam.remote[entry.path]! }
    _ = try await service.sync(game: game, info: info)
    try service.setPermissions(10, account: steam.steamID, upload: true)
    try write("new progress", apiSave)
    service.sendUpload = { _, _ in
        _ = try await service.resetLocalSaves(game: game, info: info)
        try service.setPermissions(10, account: steam.steamID, upload: true, download: true)
    }
    do { _ = try await service.sync(game: game, info: info); fatalError("stale upload committed after reset") } catch {}
    expect(steam.commits == 0 && steam.remote == originalCloud)
    expect(try service.pendingApps().isEmpty)
    log("PASS reset invalidates in-flight downloads and upload commits even after settings are re-enabled")
}
