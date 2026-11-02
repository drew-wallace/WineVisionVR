import Foundation
import CryptoKit
func log(_ text: String) { FileHandle.standardOutput.write(Data((text + "\n").utf8)) }
func expect(_ condition: Bool, _ message: String = "assertion failed", line: UInt = #line) { precondition(condition, "\(message) at line \(line)") }

@MainActor
final class FakeSteam: SteamCMSession {
    var cellID: UInt32 = 1
    var steamID: UInt64 = 76561198000000001
    var remote: [String: Data] = [:]
    var generation: UInt64 = 1
    var batches = 0
    var commits = 0
    var uploadName = ""
    var uploaded = Data()
    var failListing = false
    var failCommit = false
    var failComplete = false
    var methods: [SteamServiceMethod] = []
    func ensureConnected() async throws {}
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32] { [] }
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage { fatalError() }
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage] { fatalError() }
    func callServiceMethod(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> Data {
        methods.append(method)
        var response = ProtobufEncoder()
        switch method {
        case .cloudGetAppFileChangelist:
            if failListing { throw SteamError.disconnected }
            response.writeUInt64(fieldNumber: 1, value: generation)
            for name in remote.keys.sorted() {
                let bytes = remote[name]!
                var file = ProtobufEncoder()
                file.writeString(fieldNumber: 1, value: name)
                file.writeBytes(fieldNumber: 2, value: Data(Insecure.SHA1.hash(data: bytes)))
                file.writeUInt64(fieldNumber: 3, value: 100)
                file.writeUInt64(fieldNumber: 4, value: UInt64(bytes.count))
                response.writeBytes(fieldNumber: 2, value: file.data)
            }
        case .cloudBeginAppUploadBatch:
            batches += 1
            response.writeUInt64(fieldNumber: 1, value: 50)
            // Field 4 is files_to_delete. The client must never send it.
            var request = ProtobufDecoder(body)
            while let tag = try request.readTag() {
                expect(tag.fieldNumber != 4, "cloud delete request")
                try request.skip(wireType: tag.wireType)
            }
        case .cloudClientBeginFileUpload:
            var request = ProtobufDecoder(body)
            while let tag = try request.readTag() {
                if tag.fieldNumber == 6 { uploadName = try request.readString() }
                else { try request.skip(wireType: tag.wireType) }
            }
            var block = ProtobufEncoder()
            block.writeString(fieldNumber: 1, value: "storage.example")
            block.writeUInt64(fieldNumber: 7, value: 1)
            response.writeBytes(fieldNumber: 2, value: block.data)
        case .cloudClientCommitFileUpload:
            commits += 1
            if !failCommit { remote[uploadName] = uploaded; generation += 1 }
            response.writeBool(fieldNumber: 1, value: !failCommit)
        case .cloudCompleteAppUploadBatch:
            if failComplete { throw SteamError.disconnected }
        default: fatalError("Unexpected live service call")
        }
        return response.data
    }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("wvr-steam-test-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let drive = root.appendingPathComponent("drive_c")
        try fm.createDirectory(at: drive.appendingPathComponent("users/test"), withIntermediateDirectories: true)
        let steam = FakeSteam()
        let support = root.appendingPathComponent("state")
        var idle = true
        let service = SteamGameServices(session: steam, drive: drive, support: support, idle: { idle })
        service.downloadFile = { _, entry in steam.remote[entry.path]! }
        service.sendUpload = { bytes, _ in steam.uploaded = bytes }
        let game = DockGame(id: 10, name: "Fixture", installDir: "Fixture", library: SteamRuntimeFiles.relativeRoot + "/steamapps")
        var info = SteamAppInfo(appID: 10)
        let remote = drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/userdata/\(steam.steamID & 0xffff_ffff)/10/remote")
        try fm.createDirectory(at: remote, withIntermediateDirectories: true)
        let save = remote.appendingPathComponent("progress.save")
        try Data("old development save".utf8).write(to: save)
        try Data("old extra save".utf8).write(to: remote.appendingPathComponent("extra.save"))
        let cache = remote.deletingLastPathComponent().appendingPathComponent("remotecache.vdf")
        try Data("legacy".utf8).write(to: cache)
        steam.remote = ["progress.save": Data("actual cloud progress".utf8)]
        _ = try await service.sync(game: game, info: info)
        expect(try Data(contentsOf: save) == steam.remote["progress.save"])
        expect(!fm.fileExists(atPath: remote.appendingPathComponent("extra.save").path))
        expect(!fm.fileExists(atPath: cache.path) && steam.batches == 0)
        log("PASS first restore clears legacy saves/cache and never uploads")

        try service.markPending(10)
        expect(try service.pendingApps() == [10])
        let resumed = SteamGameServices(session: steam, drive: drive, support: support, idle: { idle })
        resumed.downloadFile = service.downloadFile; resumed.sendUpload = service.sendUpload
        expect(try resumed.pendingApps() == [10])
        try Data("new game progress".utf8).write(to: save)
        _ = try await resumed.sync(game: game, info: info)
        expect(steam.remote["progress.save"] == Data("new game progress".utf8) && steam.commits == 1)
        expect(try resumed.pendingApps().isEmpty)
        let backups = fm.enumerator(at: support.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)!
        let oldCloudSaved = backups.compactMap { $0 as? URL }.contains { (try? Data(contentsOf: $0)) == Data("actual cloud progress".utf8) }
        expect(oldCloudSaved)
        log("PASS durable pending upload recovers on restart and backs up cloud before overwrite")

        try Data("device change".utf8).write(to: save)
        steam.remote["progress.save"] = Data("other device change".utf8); steam.generation += 1
        let beforeBatches = steam.batches
        do { _ = try await resumed.sync(game: game, info: info); fatalError("conflict accepted") } catch {}
        expect(try steam.batches == beforeBatches && Data(contentsOf: save) == Data("device change".utf8))
        _ = try await resumed.sync(game: game, info: info, preferCloud: true)
        expect(try Data(contentsOf: save) == Data("other device change".utf8))
        log("PASS simultaneous changes block upload; explicit cloud restore resolves conflict")

        try service.markPending(10)
        try Data("retry me".utf8).write(to: save)
        steam.failCommit = true
        do { _ = try await service.sync(game: game, info: info); fatalError("refused commit accepted") } catch {}
        expect(try service.pendingApps() == [10])
        expect(steam.remote["progress.save"] == Data("other device change".utf8))
        steam.failCommit = false
        _ = try await service.sync(game: game, info: info)
        log("PASS refused upload retains pending journal and local progress for retry")

        idle = false
        do { _ = try await service.sync(game: game, info: info); fatalError("live Wine accepted") } catch {}
        idle = true
        steam.steamID += 1
        expect(try service.record(10, account: steam.steamID).restored == false)
        log("PASS running Wine is blocked and account journals are isolated")
        steam.steamID -= 1

        let paths = SteamCloudPaths(drive: drive, userFolder: drive.appendingPathComponent("users/test"),
            installFolder: drive.appendingPathComponent("game"), remoteFolder: remote,
            steamID: steam.steamID, overrides: [])
        expect(paths.location(cloudPath: "../escape") == nil)
        expect(paths.location(cloudPath: "/absolute") == nil)
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: remote.appendingPathComponent("escape"), withDestinationURL: outside)
        expect(paths.location(cloudPath: "escape/save") == nil)
        expect(SteamCloudDownloadInfo(host: "example.com", https: false).url == nil)
        log("PASS traversal, symlink escape and plaintext storage URLs are refused")

        // Failed first restore must not delete legacy files or permit uploads.
        let freshState = root.appendingPathComponent("fresh-state")
        let fresh = SteamGameServices(session: steam, drive: drive, support: freshState, idle: { true })
        let previous = try Data(contentsOf: save)
        steam.failListing = true
        do { _ = try await fresh.sync(game: game, info: info); fatalError("network failure accepted") } catch {}
        expect(try Data(contentsOf: save) == previous)
        steam.failListing = false
        fresh.downloadFile = { _, _ in Data("corrupt cloud bytes".utf8) }
        do { _ = try await fresh.sync(game: game, info: info); fatalError("bad checksum accepted") } catch {}
        expect(try Data(contentsOf: save) == previous)
        expect(try fresh.record(10, account: steam.steamID).restored == false)
        log("PASS network failure and bad checksums preserve local files and keep uploads locked")

        let child = SteamAppInfo.parse(appID: 20, from: ["appinfo": [
            "common": ["name": "Expansion", "type": "DLC"], "extended": ["dlcforappid": "10"]]])
        expect(child?.parentID == 10)
        var baseDepot = SteamAppInfo.DepotInfo(depotID: 11)
        baseDepot.manifests = ["public": 101]
        var ownedDepot = SteamAppInfo.DepotInfo(depotID: 12)
        ownedDepot.dlcAppID = 20; ownedDepot.manifests = ["public": 102]
        var unownedDepot = SteamAppInfo.DepotInfo(depotID: 13)
        unownedDepot.dlcAppID = 30; unownedDepot.manifests = ["public": 103]
        info.depots = [baseDepot, ownedDepot, unownedDepot]; info.ownedDLC = [20]
        expect(info.installDepots().map(\.depotID) == [11, 12])
        let apps = SteamInstallPaths.steamApps(drive: drive)
        try fm.createDirectory(at: apps, withIntermediateDirectories: true)
        let installed = [AppManifestWriter.InstalledDepot(depotID: 11, manifestGID: 101),
                         AppManifestWriter.InstalledDepot(depotID: 12, manifestGID: 102, dlcAppID: 20)]
        try AppManifestWriter.writeManifest(appID: 10, name: "Fixture", installDir: "Fixture", buildID: 1,
            steamID: steam.steamID, sizeOnDisk: 1, steamAppsPath: apps.path, installedDepots: installed)
        expect(SteamDLCStatus.inspect(info: info, owned: [], drive: drive).first?.ready == true)
        info.depots[1].manifests = ["public": 999]
        expect(SteamDLCStatus.inspect(info: info, owned: [], drive: drive).first?.ready == false)
        log("PASS only licensed DLC is selected and outdated DLC requires repair")
        try await checkMetadataRefresh()

        // Independent controls preserve both the game and cloud copy while off.
        let batchesBeforeOff = steam.batches
        try service.setPermissions(10, account: steam.steamID, upload: false, download: true)
        try Data("do not upload this".utf8).write(to: save)
        _ = try await service.sync(game: game, info: SteamAppInfo(appID: 10))
        expect(steam.batches == batchesBeforeOff)
        expect(try Data(contentsOf: save) == Data("do not upload this".utf8))
        let persisted = SteamGameServices(session: steam, drive: drive, support: support, idle: { true })
        expect(try persisted.permissions(10, account: steam.steamID) == .init(upload: false, download: true))
        try service.markPending(10)
        expect(try service.pendingApps().isEmpty)
        _ = try await service.sync(game: game, info: SteamAppInfo(appID: 10), preferCloud: true)
        expect(steam.batches == batchesBeforeOff)
        expect(try Data(contentsOf: save) == steam.remote["progress.save"])
        log("PASS uploads off survives restart and permits cloud restore without sending a save")

        try service.setPermissions(10, account: steam.steamID, download: false)
        steam.failListing = true
        _ = try await service.sync(game: game, info: SteamAppInfo(appID: 10))
        steam.failListing = false
        expect(steam.batches == batchesBeforeOff)
        log("PASS both directions off performs no cloud request")

        try service.setPermissions(10, account: steam.steamID, upload: true)
        service.downloadFile = { _, _ in fatalError("download while disabled") }
        try Data("upload only new progress".utf8).write(to: save)
        _ = try await service.sync(game: game, info: SteamAppInfo(appID: 10))
        expect(steam.remote["progress.save"] == Data("upload only new progress".utf8))
        steam.remote["cloud-only.save"] = Data("leave on server".utf8)
        _ = try await service.sync(game: game, info: SteamAppInfo(appID: 10))
        expect(!fm.fileExists(atPath: remote.appendingPathComponent("cloud-only.save").path))
        log("PASS downloads off blocks cloud file downloads while uploads can be enabled independently")

        try service.setPermissions(10, account: steam.steamID, download: true)
        service.downloadFile = { _, entry in steam.remote[entry.path]! }
        let cloudBeforeCancel = steam.remote["progress.save"]
        let commitsBeforeCancel = steam.commits
        try Data("cancel this pending upload".utf8).write(to: save)
        service.sendUpload = { bytes, _ in
            steam.uploaded = bytes
            try service.setPermissions(10, account: steam.steamID, upload: false)
        }
        do { _ = try await service.sync(game: game, info: SteamAppInfo(appID: 10)); fatalError("disabled upload committed") } catch {}
        expect(steam.commits == commitsBeforeCancel && steam.remote["progress.save"] == cloudBeforeCancel)
        expect(try service.permissions(10, account: steam.steamID).upload == false)
        log("PASS turning uploads off during a transfer prevents its cloud commit")
        try await checkLocalSaveReset(root: root.appendingPathComponent("reset-tests"))
    }
}
