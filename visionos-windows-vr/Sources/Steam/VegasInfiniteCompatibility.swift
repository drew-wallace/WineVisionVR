import Foundation
import CryptoKit

/// Remove the retired avatar adapter so the game can validate its original files.
/// Runtime dependencies belong in the Wine prefix, outside the game build.
enum VegasInfiniteCompatibility {
    static let appID = 886250
    static let originalSHA256 = "b8246e1a629b945fe526b24c3e4f002c4f6eb86aa1b5ed9744399f22a0d2ca9f"
    static let names = Set(["steam_api64.dll", "vcruntime140_1.dll", "sensapi.dll"])
    struct Package: Codable {
        let schemaVersion: Int
        let originalSHA256: String
        let filesSHA256: [String: String]
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func prepare(game: DockGame, drive: URL) throws {
        guard game.id == appID else { return }
        try MadeiraDock.validate(game, drive: drive)
        guard wine_process_is_running() == 0, wineserver_is_running() == 0,
              let resource = Bundle.main.resourceURL else {
            throw DockError.message("Close the running game before preparing Vegas Infinite compatibility.")
        }
        try restore(gameFolder: drive.appendingPathComponent(game.library + "/common/" + game.installDir),
                    packageFolder: resource.appendingPathComponent("GameCompatibility/VegasInfinite"))
    }
    static func restore(gameFolder: URL, packageFolder: URL,
                        expectedOriginalSHA256: String = VegasInfiniteCompatibility.originalSHA256,
                        writeFile: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        let fm = FileManager.default
        func fail(_ message: String) -> DockError { .message("Vegas Infinite compatibility: " + message) }
        let package = try JSONDecoder().decode(Package.self,
            from: Data(contentsOf: packageFolder.appendingPathComponent("package.json")))
        guard package.schemaVersion == 1, package.originalSHA256 == expectedOriginalSHA256,
              Set(package.filesSHA256.keys) == names else { throw fail("the adapter package could not be verified.") }
        for name in names {
            let data = try Data(contentsOf: packageFolder.appendingPathComponent(name))
            guard data.count <= 2 * 1024 * 1024, digest(data) == package.filesSHA256[name] else {
                throw fail("the adapter package could not be verified.")
            }
        }
        let plugins = gameFolder.appendingPathComponent("PokerStarsVR_Data/Plugins/x86_64")
        let gameValues = try gameFolder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard gameValues.isDirectory == true, gameValues.isSymbolicLink != true else {
            throw fail("the game folder is unsafe; files were preserved.")
        }
        let root = gameFolder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        func checked(_ file: URL) throws -> URL {
            guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root),
                  file.standardizedFileURL.path.hasPrefix(gameFolder.standardizedFileURL.path + "/") else {
                throw fail("the game folder is unsafe; files were preserved.")
            }
            var cursor = file
            while cursor.standardizedFileURL.path != gameFolder.standardizedFileURL.path {
                guard (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                    throw fail("a game path is a symbolic link; files were preserved.")
                }
                cursor.deleteLastPathComponent()
            }
            return file
        }
        func existing(_ file: URL) throws -> Data? {
            _ = try checked(file)
            if (try? fm.destinationOfSymbolicLink(atPath: file.path)) != nil {
                throw fail("a destination is a symbolic link; files were preserved.")
            }
            guard fm.fileExists(atPath: file.path) else { return nil }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let bytes = values.fileSize, bytes <= 2 * 1024 * 1024 else {
                throw fail("a destination is not a supported file; files were preserved.")
            }
            return try Data(contentsOf: file)
        }
        let entry = plugins.appendingPathComponent("steam_api64.dll")
        let ledger = gameFolder.appendingPathComponent(".winevision-vegas-compatibility.json")
        let oldLedger = try existing(ledger)
        let prior = try oldLedger.map { try JSONDecoder().decode(Package.self, from: $0) }
        if let prior {
            guard prior.schemaVersion == 1, prior.originalSHA256 == expectedOriginalSHA256,
                  Set(prior.filesSHA256.keys) == names else { throw fail("the prior adapter record is invalid.") }
        }
        guard let current = try existing(entry) else { throw fail("the Steam API library is missing.") }
        let currentHash = digest(current)
        // Never restore an old Valve DLL over a newer genuine Steam download.
        let isAdapter = currentHash == package.filesSHA256["steam_api64.dll"] ||
            currentHash == prior?.filesSHA256["steam_api64.dll"]
        let backupName = "wvr_steam_api64_original.dll"
        let backupFiles = [gameFolder.appendingPathComponent(backupName), plugins.appendingPathComponent(backupName)]
        var original: Data?
        var removals: [(URL, Data)] = []
        for file in backupFiles {
            if let before = try existing(file), digest(before) == expectedOriginalSHA256 {
                original = before
                removals.append((file, before))
            }
        }
        if isAdapter, original == nil {
            throw fail("the original Steam API backup is missing. Verify the game download before launching.")
        }
        for name in ["vcruntime140_1.dll", "sensapi.dll"] {
            let file = gameFolder.appendingPathComponent(name)
            if let before = try existing(file) {
                let hash = digest(before)
                if hash == package.filesSHA256[name] || hash == prior?.filesSHA256[name] {
                    removals.append((file, before))
                }
            }
        }
        // Restore the supported original first, then remove only verified adapter-owned files.
        // A newer/unknown game DLL and unrelated support libraries are preserved.
        var snapshots: [(URL, Data)] = []
        do {
            if isAdapter {
                snapshots.append((entry, current))
                try writeFile(original!, entry)
            }
            for (file, before) in removals {
                snapshots.append((file, before))
                try fm.removeItem(at: file)
            }
            if let oldLedger {
                snapshots.append((ledger, oldLedger))
                try fm.removeItem(at: ledger)
            }
        } catch {
            for (file, before) in snapshots.reversed() { try? before.write(to: file, options: .atomic) }
            throw error
        }
    }
}
