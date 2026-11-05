import Foundation
import CryptoKit

enum BigscreenVideoCompatibility {
    static let originalSHA256 = "6c88f56e09b810e848fcea0cb2c97ded46c08a94d8e2cd29b2146f0fab64ab04"
    struct Package: Codable {
        let schemaVersion: Int
        let originalSHA256: String
        let filesSHA256: [String: String]
    }
    enum Failure: LocalizedError {
        case invalidPackage, unsupportedGame, conflict(String), unsafePath
        var errorDescription: String? {
            switch self {
            case .invalidPackage: "The Bigscreen video adapter package could not be verified."
            case .unsupportedGame: "This Bigscreen version needs an updated video adapter. Its files were preserved."
            case .conflict(let name): "The Bigscreen video adapter preserved a different existing file: \(name)."
            case .unsafePath: "The Bigscreen video adapter could not verify the game folder."
            }
        }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func prepare(game: DockGame, drive: URL) throws {
        guard game.id == 457550 else { return }
        try MadeiraDock.validate(game, drive: drive)
        guard let resource = Bundle.main.resourceURL else { throw Failure.invalidPackage }
        let gameFolder = drive.appendingPathComponent(game.library + "/common/" + game.installDir, isDirectory: true)
        try install(gameFolder: gameFolder, packageFolder: resource.appendingPathComponent("WindowsVR/Guest/BigscreenVideo", isDirectory: true))
    }
    static func install(gameFolder: URL, packageFolder: URL) throws {
        let manager = FileManager.default
        let names = Set(["BigSoup.dll", "amfrt64.dll"])
        let package = try JSONDecoder().decode(Package.self, from: Data(contentsOf: packageFolder.appendingPathComponent("package.json")))
        guard package.schemaVersion == 1, package.originalSHA256 == originalSHA256,
              Set(package.filesSHA256.keys) == names else { throw Failure.invalidPackage }
        var source: [String: Data] = [:]
        for name in names {
            let data = try Data(contentsOf: packageFolder.appendingPathComponent(name))
            guard digest(data) == package.filesSHA256[name] else { throw Failure.invalidPackage }
            source[name] = data
        }
        let plugins = gameFolder.appendingPathComponent("Bigscreen_Data/Plugins/x86_64", isDirectory: true)
        let resolvedGame = gameFolder.resolvingSymlinksInPath().standardizedFileURL.path
        guard plugins.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedGame + "/") else { throw Failure.unsafePath }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: plugins.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure.unsafePath }
        // Forwarded exports and AMF's dynamic loader search the application
        // directory. Keep the Unity-facing forwarder in its plugin folder.
        func destination(_ name: String) -> URL {
            (name == "BigSoup.dll" ? plugins : gameFolder).appendingPathComponent(name)
        }
        func existing(_ name: String) throws -> Data? {
            let url = destination(name)
            guard manager.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true else { throw Failure.unsafePath }
            return try Data(contentsOf: url)
        }
        let ledgerName = ".winevision-video.json"
        let prior = try existing(ledgerName).flatMap { try JSONDecoder().decode(Package.self, from: $0) }
        if let prior {
            guard prior.schemaVersion == 1, prior.originalSHA256 == originalSHA256,
                  Set(prior.filesSHA256.keys) == names else { throw Failure.invalidPackage }
        }
        guard let current = try existing("BigSoup.dll") else { throw Failure.unsupportedGame }
        let currentHash = digest(current)
        guard currentHash == originalSHA256 || currentHash == package.filesSHA256["BigSoup.dll"] ||
              currentHash == prior?.filesSHA256["BigSoup.dll"] else { throw Failure.unsupportedGame }
        let saved = try existing("wvr_bigsoup_original.dll")
        if let saved { guard digest(saved) == originalSHA256 else { throw Failure.conflict("wvr_bigsoup_original.dll") } }
        guard saved != nil || currentHash == originalSHA256 else { throw Failure.conflict("wvr_bigsoup_original.dll") }
        let previousAMF = try existing("amfrt64.dll")
        if let previousAMF {
            let hash = digest(previousAMF)
            guard hash == package.filesSHA256["amfrt64.dll"] || hash == prior?.filesSHA256["amfrt64.dll"] else { throw Failure.conflict("amfrt64.dll") }
        }
        if saved == nil { try current.write(to: destination("wvr_bigsoup_original.dll"), options: .atomic) }
        do {
            try source["amfrt64.dll"]!.write(to: destination("amfrt64.dll"), options: .atomic)
            try source["BigSoup.dll"]!.write(to: destination("BigSoup.dll"), options: .atomic)
            try JSONEncoder().encode(package).write(to: destination(ledgerName), options: .atomic)
        } catch {
            // Preserve the exact entry state on a partial installation. The
            // separately verified original also remains available for recovery.
            try? current.write(to: destination("BigSoup.dll"), options: .atomic)
            if let previousAMF { try? previousAMF.write(to: destination("amfrt64.dll"), options: .atomic) }
            else { try? manager.removeItem(at: destination("amfrt64.dll")) }
            throw error
        }
    }
}
