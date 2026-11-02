import Foundation
import CryptoKit
import Darwin

/// End-user downloads, never bundled third-party DLLs. Cache survives Steam uninstall.
actor RiskOfRain2HealthBarRepair {
    static let shared = RiskOfRain2HealthBarRepair()
    static let appID = 632360
    private var busy = false

    struct Package: Codable, Sendable {
        let id: String
        let url: URL
        let bytes: Int
        let sha256: String
    }
    struct Asset: Codable, Sendable {
        let package: String
        let member: String
        let path: String
        let bytes: Int
        let sha256: String
    }
    struct Recipe: Codable, Sendable {
        let schemaVersion: Int
        let steamAppID: Int
        let revision: String
        let packages: [Package]
        let assets: [Asset]

        func validate() throws {
            func hash(_ s: String) -> Bool { s.count == 64 && s.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
            guard schemaVersion == 1, steamAppID == RiskOfRain2HealthBarRepair.appID,
                  SteamRuntimeFiles.validPath(revision), !packages.isEmpty, packages.count <= 3,
                  Set(packages.map(\.id)).count == packages.count,
                  !assets.isEmpty, assets.count <= 32,
                  Set(assets.map { $0.path.lowercased() }).count == assets.count,
                  assets.contains(where: { $0.path == "winhttp.dll" }),
                  packages.allSatisfy({ $0.bytes > 0 && $0.bytes <= 8 * 1024 * 1024 && hash($0.sha256) &&
                      SteamRuntimeFiles.validPath($0.id) && Self.allowed($0.url) }),
                  assets.allSatisfy({ asset in asset.bytes > 0 && asset.bytes <= 2 * 1024 * 1024 && hash(asset.sha256) &&
                      SteamRuntimeFiles.validPath(asset.path) && SteamRuntimeFiles.validPath(asset.member) &&
                      packages.contains(where: { $0.id == asset.package }) &&
                      (asset.path == "winhttp.dll" || asset.path == ".doorstop_version" || asset.path == "doorstop_config.ini" ||
                       asset.path.hasPrefix("BepInEx/core/") || asset.path.hasPrefix("BepInEx/plugins/MetalSafeBars/") ||
                       asset.path == "BepInEx/config/BepInEx.DO_NOT_MODIFY.cfg") }) else { throw Failure.invalidRecipe }
        }

        static func allowed(_ url: URL) -> Bool {
            url.scheme == "https" && ["thunderstore.io", "ccdn.thunderstore.io", "gcdn.thunderstore.io", "api.nuget.org", "globalcdn.nuget.org"].contains(url.host ?? "") &&
                (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
        }
    }

    enum Failure: LocalizedError {
        case invalidRecipe, invalidPackage(String), unsafePath, conflict(String), activeSession
        var errorDescription: String? {
            switch self {
            case .invalidRecipe: "The Risk of Rain 2 health-bar repair package list is invalid."
            case .invalidPackage(let name): "The Risk of Rain 2 health-bar repair could not verify \(name). Check the connection and try again."
            case .unsafePath: "The Risk of Rain 2 health-bar repair found an unsafe folder. Files were preserved."
            case .conflict(let name): "The Risk of Rain 2 health-bar repair preserved a different existing file: \(name). Resolve the conflicting mod before retrying."
            case .activeSession: "Close the running game before preparing the Risk of Rain 2 health-bar repair."
            }
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Both download completion and the launch adapter use the same path resolver.
    static func prepare(game: DockGame, drive: URL) async throws {
        guard game.id == appID else { return }
        try MadeiraDock.validate(game, drive: drive)
        guard let recipeURL = Bundle.main.url(forResource: "healthbars", withExtension: "json", subdirectory: "GameCompatibility/RiskOfRain2"),
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { throw Failure.invalidRecipe }
        let recipe = try JSONDecoder().decode(Recipe.self, from: Data(contentsOf: recipeURL))
        try await shared.prepare(appID: game.id, drive: drive,
            gameRelativePath: game.library + "/common/" + game.installDir,
            cache: documents.appendingPathComponent("WindowsVR/CompatibilityAssets/RiskOfRain2Healthbars"), recipe: recipe,
            canModify: { wine_process_is_running() == 0 && wineserver_is_running() == 0 })
    }

    /// Valid matching files are adopted, missing files restored, different files preserved.
    /// Networking finishes before any game files change. No Wine process is launched here.
    func prepare(appID: Int, drive: URL, gameRelativePath: String, cache: URL, recipe: Recipe,
                 canModify: @Sendable () -> Bool,
                 download: @Sendable (Package) async throws -> Data = RiskOfRain2HealthBarRepair.download) async throws {
        guard appID == Self.appID else { return }
        guard !busy, canModify() else { throw Failure.activeSession }
        busy = true; defer { busy = false }
        try recipe.validate()
        let fm = FileManager.default
        let root = try Self.directory(drive, create: false)
        let game = try Self.directory(SteamRuntimeFiles.destination(gameRelativePath, under: root), create: false)
        let executable = try SteamRuntimeFiles.destination("Risk of Rain 2.exe", under: game)
        guard try Self.existingData(executable, max: 16 * 1024 * 1024) != nil else { throw Failure.unsafePath }
        let cache = try Self.directory(cache, create: true)
        let assetsRoot = try Self.directory(SteamRuntimeFiles.destination(recipe.revision + "/Assets", under: cache), create: true)
        var inputs: [String: Data] = [:]
        var missing: [Asset] = []
        // Preflight every destination, including configuration, before downloading or publishing.
        for asset in recipe.assets {
            let target = try SteamRuntimeFiles.destination(asset.path, under: game)
            if let data = try Self.existingData(target) {
                guard Self.matches(data, asset) else { throw Failure.conflict(asset.path) }
                inputs[asset.path] = data
            } else { missing.append(asset) }
        }
        let config = try SteamRuntimeFiles.destination("BepInEx/config/BepInEx.cfg", under: game)
        let before = try Self.existingData(config, max: 1024 * 1024)
        let after = try Self.configuration(before)
        for asset in recipe.assets where inputs[asset.path] == nil {
            let cached = try SteamRuntimeFiles.destination(asset.path, under: assetsRoot)
            if let data = try Self.existingData(cached), Self.matches(data, asset) { inputs[asset.path] = data }
        }
        for package in recipe.packages where recipe.assets.contains(where: { $0.package == package.id && inputs[$0.path] == nil }) {
            try Task.checkCancellation()
            let data = try await download(package)
            guard data.count == package.bytes, Self.digest(data) == package.sha256 else { throw Failure.invalidPackage(package.id) }
            var found = Set<String>()
            try SteamRuntimeFiles.unpack(data) { name, bytes in
                for asset in recipe.assets where asset.package == package.id && asset.member == name {
                    guard Self.matches(bytes, asset), found.insert(asset.path).inserted else { throw Failure.invalidPackage(package.id) }
                    if inputs[asset.path] == nil { inputs[asset.path] = bytes }
                }
            }
            guard recipe.assets.filter({ $0.package == package.id }).allSatisfy({ found.contains($0.path) }) else { throw Failure.invalidPackage(package.id) }
        }
        try Task.checkCancellation()
        guard canModify() else { throw Failure.activeSession }
        // Seed the persistent cache even when adopting a previously installed manual repair.
        for asset in recipe.assets {
            guard let bytes = inputs[asset.path], Self.matches(bytes, asset) else { throw Failure.invalidPackage(asset.path) }
            let cached = try SteamRuntimeFiles.destination(asset.path, under: assetsRoot)
            if (try Self.existingData(cached)).map({ Self.matches($0, asset) }) != true {
                try Self.directory(cached.deletingLastPathComponent(), create: true)
                try bytes.write(to: cached, options: .atomic)
            }
        }
        // Cancellation before this point has made no game changes. Publication is synchronous,
        // and an interrupted launch can finish any missing matching files on its next attempt.
        let staging = game.appendingPathComponent(".winevision-healthbars-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for asset in missing { try inputs[asset.path]!.write(to: staging.appendingPathComponent(Self.digest(Data(asset.path.utf8))), options: .withoutOverwriting) }
        if before != after {
            if let before {
                let backups = try Self.directory(SteamRuntimeFiles.destination("ConfigBackups", under: cache), create: true)
                let backup = try SteamRuntimeFiles.destination(Self.digest(before) + ".cfg", under: backups)
                if let existing = try Self.existingData(backup) { guard existing == before else { throw Failure.unsafePath } }
                else { try before.write(to: backup, options: .withoutOverwriting) }
            }
            // Recheck the snapshot before changing the one required loader setting.
            guard try Self.existingData(config, max: 1024 * 1024) == before else { throw Failure.conflict("BepInEx.cfg") }
            try Self.directory(config.deletingLastPathComponent(), create: true)
            try after.write(to: config, options: .atomic)
        }
        for asset in missing.sorted(by: { ($0.path == "winhttp.dll" ? 1 : 0, $0.path) < ($1.path == "winhttp.dll" ? 1 : 0, $1.path) }) {
            let target = try SteamRuntimeFiles.destination(asset.path, under: game)
            try Self.directory(target.deletingLastPathComponent(), create: true)
            let staged = staging.appendingPathComponent(Self.digest(Data(asset.path.utf8)))
            // Exclusive rename preserves a concurrently added mod and leaves no extra hard link.
            let result = staged.path.withCString { from in target.path.withCString { to in
                renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL))
            } }
            guard result == 0 else { throw Failure.conflict(asset.path) }
        }
        LaunchLogFile.append("notice", "Risk of Rain 2 health-bar repair verified; restored \(missing.count) files")
    }

    private static func matches(_ data: Data, _ asset: Asset) -> Bool { data.count == asset.bytes && digest(data) == asset.sha256 }

    @discardableResult
    private static func directory(_ url: URL, create: Bool) throws -> URL {
        let fm = FileManager.default
        // Reject symlinks in every existing component, while allowing the OS's /var alias.
        var node = url.standardizedFileURL
        while node.path != "/" {
            if (try? node.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true,
               node.path != "/var", node.path != "/tmp" { throw Failure.unsafePath }
            node.deleteLastPathComponent()
        }
        if create { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw Failure.unsafePath }
        return url.resolvingSymlinksInPath()
    }

    private static func existingData(_ url: URL, max: Int = 2 * 1024 * 1024) throws -> Data? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let bytes = values.fileSize, bytes <= max else { throw Failure.unsafePath }
        return try Data(contentsOf: url)
    }

    /// Preserve comments, line endings and all unrelated settings. Reject ambiguous INI keys.
    static func configuration(_ data: Data?) throws -> Data {
        guard let data else { return Data("[Preloader]\nApplyRuntimePatches = false\n".utf8) }
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw Failure.conflict("BepInEx.cfg") }
        if text.hasPrefix("\u{feff}") { text.removeFirst() }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        var sections: [Int] = [], keys: [Int] = [], inSection = false
        for i in lines.indices {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inSection = line.caseInsensitiveCompare("[Preloader]") == .orderedSame; if inSection { sections.append(i) } }
            if inSection, !line.hasPrefix("#"), !line.hasPrefix(";"),
               let equal = line.firstIndex(of: "="), line[..<equal].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("ApplyRuntimePatches") == .orderedSame { keys.append(i) }
        }
        guard sections.count <= 1, keys.count <= 1 else { throw Failure.conflict("BepInEx.cfg") }
        if let key = keys.first {
            let line = lines[key], equal = line.firstIndex(of: "=")!
            let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if value.caseInsensitiveCompare("false") == .orderedSame { return data }
            guard value.caseInsensitiveCompare("true") == .orderedSame else { throw Failure.conflict("BepInEx.cfg") }
            let start = line.index(after: equal)
            let leading = line[start...].prefix { $0 == " " || $0 == "\t" }
            let trailing = line[start...].reversed().prefix { $0 == " " || $0 == "\t" }.reversed()
            lines[key] = String(line[...equal]) + String(leading) + "false" + String(trailing)
        } else if let section = sections.first { lines.insert("ApplyRuntimePatches = false", at: section + 1) }
        else { lines += ["", "[Preloader]", "ApplyRuntimePatches = false", ""] }
        return Data(((data.starts(with: [0xef, 0xbb, 0xbf]) ? "\u{feff}" : "") + lines.joined(separator: newline)).utf8)
    }

    private static func download(_ package: Package) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config, delegate: RepairDownloadLimit(bytes: package.bytes), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: package.url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let url = http.url, Recipe.allowed(url),
              (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize == package.bytes else { throw Failure.invalidPackage(package.id) }
        return try Data(contentsOf: temporary)
    }
}

private final class RepairDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let bytes: Int
    init(bytes: Int) { self.bytes = bytes }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { RiskOfRain2HealthBarRepair.Recipe.allowed($0) } == true ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > bytes { downloadTask.cancel() }
    }
}
