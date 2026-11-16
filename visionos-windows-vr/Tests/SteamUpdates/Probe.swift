import Foundation
import CryptoKit

enum SteamLog {
    static func trace(_ text: String) {}
    static func event(_ text: String) { print(text) }
}
func expect(_ condition: Bool, _ message: String = "assertion failed", line: UInt = #line) {
    precondition(condition, "\(message) at line \(line)")
}

@MainActor final class UpdateSteam: SteamCMSession {
    let cellID: UInt32 = 1
    let steamID: UInt64 = 76561198000000001
    func ensureConnected() async throws {}
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32] { [] }
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage {
        var response = ProtobufEncoder()
        response.writeUInt32(fieldNumber: 1, value: 1)
        response.writeBytes(fieldNumber: 3, value: Data(repeating: 0x42, count: 32))
        return .init(eMsg: responseEMsg, rawEMsg: responseEMsg.rawValue, isProtobuf: true,
                     header: CMsgProtoBufHeader(), body: response.data)
    }
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage] { fatalError() }
    func callServiceMethod(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> Data { Data() }
}

@main struct Probe {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        let apps = root.appendingPathComponent("steamapps")
        let cache = root.appendingPathComponent("chunks")
        let transfers = SteamBackgroundTransfers(configuration: .ephemeral, cacheDirectory: cache, identifier: "update-test")
        let downloader = DepotDownloader(session: UpdateSteam(), transfers: transfers)
        downloader.contentHosts = { _ in [CommandLine.arguments[1]] }
        var info = SteamAppInfo(appID: 10)
        info.name = "Fixture"; info.installDir = "Fixture"; info.buildID = 1
        var depot = SteamAppInfo.DepotInfo(depotID: 11)
        depot.manifests = ["public": 101]
        info.depots = [depot]
        expect(SteamUpdateStatus.inspect(info, steamApps: apps) == .unknown)
        let folder = try await downloader.install(info, steamApps: apps) { _ in }
        expect(SteamUpdateStatus.inspect(info, steamApps: apps) == .upToDate)
        expect(try Data(contentsOf: folder.appendingPathComponent("game.bin")) == Data("AAAABBBBCCCC".utf8))
        expect(!fm.fileExists(atPath: apps.appendingPathComponent("downloading/10").path))
        try Data("user-modified".utf8).write(to: folder.appendingPathComponent("modified.bin"))
        try Data("save data".utf8).write(to: folder.appendingPathComponent("progress.save"))
        try Data("mod data".utf8).write(to: folder.appendingPathComponent("mod.dll"))
        info.depots[0].manifests = ["public": 102]
        // A depot-only change is sufficient even when the build is unchanged.
        expect(SteamUpdateStatus.inspect(info, steamApps: apps) == .available)
        info.buildID = 2
        var observed: [SteamDownloadProgress] = []
        _ = try await downloader.install(info, steamApps: apps) { observed.append($0) }
        expect(try Data(contentsOf: folder.appendingPathComponent("game.bin")) == Data("CCCCNEW!AAAA".utf8))
        let downloading = observed.first { $0.phase == .downloading }!
        expect(downloading.reusedBytes > 0 && downloading.totalBytes < downloading.reusedBytes)
        expect(observed.last?.doneBytes == downloading.totalBytes)
        expect(!fm.fileExists(atPath: folder.appendingPathComponent("old").path))
        expect(!fm.fileExists(atPath: folder.appendingPathComponent("empty.bin").path))
        expect(!fm.fileExists(atPath: folder.appendingPathComponent("empty-dir").path))
        expect(try fm.contentsOfDirectory(atPath: folder.path).filter { $0.lowercased() == "game.bin" }.count == 1)
        expect(try String(contentsOf: folder.appendingPathComponent("modified.bin"), encoding: .utf8) == "user-modified")
        expect(fm.fileExists(atPath: folder.appendingPathComponent("progress.save").path))
        expect(fm.fileExists(atPath: folder.appendingPathComponent("mod.dll").path))
        expect(!DepotDownloader.hasPartialDownload(appID: 10, steamApps: apps))
        expect(try fm.contentsOfDirectory(atPath: cache.path).isEmpty)
        expect(SteamUpdateStatus.inspect(info, steamApps: apps) == .upToDate)
        print("PASS full install, depot/build update detection, moved-chunk reuse and residual cleanup")

        info.depots[0].manifests = ["public": 103]; info.buildID = 3
        _ = try await downloader.install(info, steamApps: apps) { _ in }
        expect(try Data(contentsOf: folder.appendingPathComponent("game.bin")) == Data("AAAACCCC".utf8))
        print("PASS shrinking/reordered files reuse old bytes before truncation")

        // Cancelling an update after local verification keeps the old install
        // record and inventory, marks it incomplete and remains resumable.
        info.depots[0].manifests = ["public": 102]; info.buildID = 2
        let cancelledInfo = info
        let interrupted = Task { @MainActor in
            try await downloader.install(cancelledInfo, steamApps: apps) { progress in
                if progress.phase == .downloading { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await interrupted.value; fatalError("cancelled update succeeded") }
        catch { expect(error is CancellationError) }
        expect(SteamInstallFiles.buildID(appID: 10, steamApps: apps) == 3)
        expect(DepotDownloader.hasPartialDownload(appID: 10, steamApps: apps))
        _ = try await downloader.install(cancelledInfo, steamApps: apps) { _ in }
        info.depots[0].manifests = ["public": 103]; info.buildID = 3
        _ = try await downloader.install(info, steamApps: apps) { _ in }
        expect(!DepotDownloader.hasPartialDownload(appID: 10, steamApps: apps))
        print("PASS cancelled update preserves install record and resumes with clean completion")

        // A stale journal must never bless corrupt data on disk.
        let journal = apps.appendingPathComponent("downloading/10")
        try fm.createDirectory(at: journal, withIntermediateDirectories: true)
        try Data("0\n1\n".utf8).write(to: journal.appendingPathComponent("depot_11_103.journal"))
        try Data("BAD!CCCC".utf8).write(to: folder.appendingPathComponent("game.bin"))
        let old = DepotManifest(depotID: 11, manifestGID: 103, creationTime: 0, totalUncompressedSize: 8, totalCompressedSize: 8,
            files: [.init(filename: "game.bin", size: 8, flags: 0, chunks: [chunk("AAAA", 0), chunk("CCCC", 4)])])
        let plan = DepotDownloader.DepotPlan(depotID: 11, manifestGID: 103, key: Data(), manifest: old,
            hosts: [], auth: [:], declaredSize: 8, health: ContentHostHealth())
        let prepared = try DepotDownloader.prepare(plans: [plan], installURL: folder, journalDir: journal)
        expect(prepared.pending[0].count == 1 && prepared.pending[0][0].chunk == 0)
        expect(prepared.totalBytes == 4 && prepared.reusedBytes == 4)
        print("PASS resume verifies journaled chunks and fetches only corrupt/missing data")

        let outside = root.appendingPathComponent("outside.bin")
        try Data("AAAA".utf8).write(to: outside)
        let link = folder.appendingPathComponent("link.bin")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        var unsafe = old
        unsafe.files = [.init(filename: "link.bin", size: 4, flags: 0, chunks: [chunk("AAAA", 0)])]
        try DepotDownloader.cleanObsoleteFiles(previous: [unsafe], current: [], installURL: folder)
        expect(fm.fileExists(atPath: outside.path))
        print("PASS cleanup stays inside the game folder and preserves linked files")
        let owner = AppManifestWriter.InstalledDepot(depotID: 11, manifestGID: 103)
        try AppManifestWriter.writeManifest(appID: 20, name: "Owner", installDir: "Fixture", buildID: 1,
            steamID: 1, steamAppsPath: apps.path, installedDepots: [owner])
        try AppManifestWriter.writeManifest(appID: 10, name: "Fixture", installDir: "Fixture", buildID: 3,
            steamID: 1, steamAppsPath: apps.path, installedDepots: [], sharedDepots: [(11, 20)])
        expect(SteamUpdateStatus.inspect(info, steamApps: apps) == .upToDate)
        info.depots[0].manifests = ["public": 104]
        expect(SteamUpdateStatus.inspect(info, steamApps: apps) == .available)
        print("PASS update detection resolves shared-depot owner records")
        // Uninstall removes only this game and the shared records describing
        // the same folder. Separate games, user saves and cloud journals survive.
        let unrelatedFolder = apps.appendingPathComponent("common/Other")
        try fm.createDirectory(at: unrelatedFolder, withIntermediateDirectories: true)
        try Data("other game".utf8).write(to: unrelatedFolder.appendingPathComponent("keep.bin"))
        try AppManifestWriter.writeManifest(appID: 30, name: "Other", installDir: "Other", buildID: 1,
            steamID: 1, steamAppsPath: apps.path, installedDepots: [])
        let saves = root.appendingPathComponent("userdata/10/save.dat")
        try fm.createDirectory(at: saves.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("saved progress".utf8).write(to: saves)
        let inventory = apps.appendingPathComponent("winevision-manifests/10.json")
        expect(fm.fileExists(atPath: inventory.path))
        // A linked game directory is rejected before any install record is removed.
        let alias = apps.appendingPathComponent("common/Alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: unrelatedFolder)
        do {
            try SteamInstallFiles.delete(appID: 10, folderName: "Alias", steamApps: apps)
            fatalError("uninstall followed a linked folder")
        } catch {}
        expect(SteamInstallFiles.record(appID: 10, steamApps: apps) != nil)
        expect(fm.fileExists(atPath: inventory.path))
        do {
            try SteamInstallFiles.delete(appID: 10, folderName: "../Other", steamApps: apps)
            fatalError("uninstall accepted traversal")
        } catch {}
        try SteamInstallFiles.delete(appID: 10, folderName: "Fixture", steamApps: apps)
        expect(!fm.fileExists(atPath: folder.path))
        expect(SteamInstallFiles.record(appID: 10, steamApps: apps) == nil)
        expect(SteamInstallFiles.record(appID: 20, steamApps: apps) == nil)
        expect(SteamInstallFiles.record(appID: 30, steamApps: apps) != nil)
        expect(fm.fileExists(atPath: unrelatedFolder.appendingPathComponent("keep.bin").path))
        expect(fm.fileExists(atPath: saves.path) && fm.fileExists(atPath: outside.path))
        expect(!fm.fileExists(atPath: journal.path))
        expect(!fm.fileExists(atPath: apps.appendingPathComponent("winevision-manifests/10.json").path))
        expect(SteamUpdateStatus.inspect(info, steamApps: apps) == .unknown)
        try SteamInstallFiles.delete(appID: 10, folderName: "Fixture", steamApps: apps)
        print("PASS uninstall removes game, inventory, shared records and partial downloads; preserves other games and external saves; rejects unsafe folders and permits retry")
        print("STEAM UPDATE CHECKS PASSED")
    }

    static func chunk(_ text: String, _ offset: UInt64) -> DepotManifest.ChunkEntry {
        .init(sha: Data(Insecure.SHA1.hash(data: Data(text.utf8))), crc: 0, offset: offset,
              compressedSize: UInt32(text.utf8.count), uncompressedSize: UInt32(text.utf8.count))
    }
}
