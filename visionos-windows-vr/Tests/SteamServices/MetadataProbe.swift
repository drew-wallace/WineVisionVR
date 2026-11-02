import Foundation
import CryptoKit

@MainActor
final class MetadataSteam: SteamCMSession {
    var cellID: UInt32 = 1
    var steamID: UInt64 = 76561198000000001
    var appRequests = 0
    var licenseRequests = 0
    var serveApp = true
    var httpMetadata = false
    static let metadata = Data(#""appinfo" { "common" { "name" "Fixture" "type" "Game" } "config" { "installdir" "Fixture" } "ufs" { "quota" "100000" } }"#.utf8)
    func ensureConnected() async throws {}
    func awaitLicenseList(timeout: TimeInterval) async throws -> [UInt32] { licenseRequests += 1; return [1] }
    private func message(_ kind: EMsg, _ bytes: Data) -> SteamMessageCodec.IncomingMessage {
        .init(eMsg: kind, rawEMsg: kind.rawValue, isProtobuf: true, header: CMsgProtoBufHeader(), body: bytes)
    }
    func sendAndWait(eMsg: EMsg, body: Data, responseEMsg: EMsg, timeout: TimeInterval) async throws -> SteamMessageCodec.IncomingMessage {
        message(responseEMsg, Data())
    }
    func sendAndWaitPICS(eMsg: EMsg, body: Data, timeout: TimeInterval) async throws -> [SteamMessageCodec.IncomingMessage] {
        var request = ProtobufDecoder(body), apps = false, packages = false
        while let tag = try request.readTag() {
            if tag.fieldNumber == 1 { packages = true }
            if tag.fieldNumber == 2 { apps = true }
            try request.skip(wireType: tag.wireType)
        }
        var response = ProtobufEncoder()
        if packages {
            var ids = Data([0]); ids.append(Data("appids\0".utf8)); ids.append(2); ids.append(Data("0\0".utf8))
            ids.append(contentsOf: [10, 0, 0, 0, 8])
            var package = ProtobufEncoder()
            package.writeUInt32(fieldNumber: 1, value: 1)
            package.writeBytes(fieldNumber: 5, value: ids)
            response.writeBytes(fieldNumber: 3, value: package.data)
        }
        if apps {
            appRequests += 1
            if serveApp {
                var app = ProtobufEncoder()
                app.writeUInt32(fieldNumber: 1, value: 10)
                if httpMetadata {
                    app.writeBytes(fieldNumber: 4, value: Data(Insecure.SHA1.hash(data: Self.metadata)))
                    app.writeUInt32(fieldNumber: 7, value: UInt32(Self.metadata.count))
                    response.writeString(fieldNumber: 8, value: "appinfo.steampowered.com")
                } else { app.writeBytes(fieldNumber: 5, value: Self.metadata) }
                response.writeBytes(fieldNumber: 1, value: app.data)
            }
        }
        return [message(.clientPICSProductInfoResponse, response.data)]
    }
    func callServiceMethod(method: SteamServiceMethod, body: Data, timeout: TimeInterval) async throws -> Data { fatalError() }
}

actor MetadataHTTPRequests {
    var count = 0
    func record() { count += 1 }
    func total() -> Int { count }
}

@MainActor
func checkMetadataRefresh() async throws {
    let records = [DockGame(id: 10, name: "Installed Fixture", installDir: "Disk Folder", library: "steamapps"),
                   DockGame(id: 20, name: "Another Installed", installDir: "Second", library: "steamapps"),
                   DockGame(id: 30, name: "Partial download", installDir: "Partial", library: "steamapps", installed: false)]
    let withoutSteam = SteamInstalledLibrary.games(records: records, metadata: [])
    expect(Set(withoutSteam.map(\.id)) == [10, 20])
    expect(withoutSteam.first(where: { $0.id == 10 })?.name == "Installed Fixture")
    var details = SteamAppInfo(appID: 10)
    details.name = "Fixture with artwork"; details.headerImage = "header.jpg"; details.installDir = "Server Folder"
    var other = SteamAppInfo(appID: 99); other.name = "Owned but not installed"
    let duringRefresh = SteamInstalledLibrary.games(records: records + [records[0]],
        metadata: [SteamOwnedGame(details), SteamOwnedGame(other)])
    expect(Set(duringRefresh.map(\.id)) == [10, 20] && duringRefresh.count == 2)
    expect(duringRefresh.first(where: { $0.id == 10 })?.headerImage == "header.jpg")
    expect(duringRefresh.first(where: { $0.id == 10 })?.installDir == "Disk Folder")
    let failedRefresh = SteamInstalledLibrary.games(records: records, metadata: [])
    expect(failedRefresh.map(\.id) == withoutSteam.map(\.id))
    let afterUninstall = SteamInstalledLibrary.games(records: [records[1]], metadata: duringRefresh)
    expect(afterUninstall.map(\.id) == [20])
    log("PASS Installed works with no Steam response, survives refresh failure, enriches cards and follows local uninstalls")

    let singleGameSession = MetadataSteam()
    let singleGameFetcher = SteamLibraryFetcher(session: singleGameSession)
    expect(try await singleGameFetcher.fetchAppInfo(appID: 10)?.name == "Fixture")
    expect(singleGameSession.appRequests == 1 && singleGameSession.licenseRequests == 0)
    log("PASS fetching one installed game's metadata never waits for the owned-library scan")

    let session = MetadataSteam()
    // Test a real fetcher with a single metadata-bearing response, followed by
    // empty redundant responses, as can happen while recovering a save retry.
    let tested = SteamLibraryFetcher(session: session)
    let owned = try await tested.fetchOwnedApps()
    expect(owned.map(\.appID) == [10])
    session.serveApp = false
    expect(try await tested.fetchInstallInfo(appID: 10)?.cloudEnabled == true)
    expect(session.appRequests == 1)
    expect(try await tested.fetchAppInfo(appID: 10)?.name == "Fixture")
    expect(session.appRequests == 1)
    session.steamID += 1
    expect(try await tested.fetchAppInfo(appID: 10) == nil)
    expect(tested.ownedApps.isEmpty)
    log("PASS installed-game/save checks reuse freshly loaded metadata and invalidate it on account change")

    let httpSteam = MetadataSteam()
    httpSteam.httpMetadata = true
    let httpFetcher = SteamLibraryFetcher(session: httpSteam)
    let requests = MetadataHTTPRequests()
    let zipped = Data(base64Encoded: "H4sIAAAAAAAC/1NKLCjIzEvLV1KoVlBKzs/Nzc8DM/MSc1OVFJTcMitKSotArJLKAhDlDhavBanNS8tMB6vNzCsuSczJScksQtYBVFOaVgxWUFiaX5IIlDM0AAGQVC0AKn28g3gAAAA=")!
    httpFetcher.downloadAppInfo = { url in
        expect(url.scheme == "https" && url.path.hasPrefix("/appinfo/10/sha/"))
        await requests.record()
        return zipped
    }
    expect(try await httpFetcher.fetchOwnedApps().first?.appID == 10)
    expect(try await httpFetcher.fetchInstallInfo(appID: 10)?.cloudEnabled == true)
    expect(try await httpFetcher.fetchOwnedApps().first?.appID == 10)
    expect(await requests.total() == 1)
    expect(SteamPICSMetadata.url(appID: 10, sha: Data(repeating: 0, count: 20), host: "evil.example") == nil)
    expect(SteamPICSMetadata.url(appID: 10, sha: Data(repeating: 0, count: 20), host: "clientconfig.akamai.steamstatic.com:80")?.host == "clientconfig.akamai.steamstatic.com")
    expect(SteamPICSMetadata.url(appID: 10, sha: Data(repeating: 0, count: 20), host: "")?.scheme == "https")
    do { _ = try SteamPICSMetadata.decode(zipped, expectedSHA: Data(repeating: 0, count: 20)); fatalError("bad metadata SHA accepted") } catch {}
    log("PASS HTTP-only PICS records fetch verified gzip metadata and reuse the matching digest on refresh")

    var visited: [Int] = [], failures: [Int] = []
    await SteamLibraryMaintenance.run([10,20,30], canContinue: { true }, operation: { id in
        visited.append(id)
        if id == 10 { throw SteamFileError.invalid("metadata unavailable") }
        if id == 20 { throw SteamError.connectionTimeout }
    }, onFailure: { id, _ in failures.append(id) })
    expect(visited == [10,20,30] && failures == [10,20])
    log("PASS a missing game or failed cloud retry cannot abort library maintenance")

    let original = Data(#""UserLocalConfigStore" { "friends" { "keep" "untouched" } "Software" { "Valve" { "Steam" { "apps" { "10" { "LastPlayed" "123" "cloudenabled" "1" } "20" { "cloudenabled" "1" } } } } } }"#.utf8)
    var parser = try SteamKeyValues(SteamCloudClientSettings.updating(original, appID: 10, enabled: false))
    let root = try parser.read()
    let store = root["UserLocalConfigStore"]!
    let apps = store["Software"]?["Valve"]?["Steam"]?["apps"]
    expect(apps?["10"]?["cloudenabled"]?.string == "0")
    expect(apps?["20"]?["cloudenabled"]?.string == "1" && apps?["10"]?["LastPlayed"]?.string == "123")
    expect(store["friends"]?["keep"]?.string == "untouched")
    let legacyHold = try JSONDecoder().decode(SteamGameServices.Record.self, from: Data(#"{"restored":true,"baseline":{},"pendingUpload":false,"uploadsBlocked":true}"#.utf8))
    expect(!legacyHold.permissions.upload && legacyHold.permissions.download)
    log("PASS guest Cloud preference preserves unrelated settings and imports a temporary upload hold")
}
