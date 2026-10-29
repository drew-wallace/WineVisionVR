import Foundation
import CryptoKit
import Darwin

/// Scoped experimental profile for Steam 2868840. Verified local assets are
/// required before the profile can be enabled for ordinary library launches.
enum WindowsVRAngleTrial {
    struct Asset: Codable, Sendable {
        let name: String
        let sha256: String
    }

    static let assets = [
        Asset(name: "libEGL.dll", sha256: "9c1cc55f2023e724e863a040aaea718ebaf471157c77010aec0b8c49785ec710"),
        Asset(name: "libGLESv2.dll", sha256: "7e98b68c93f8b12f4c38084abad532f3396367e9dddc13fa876e25ff17b8410c")
    ]
    static let arguments = "--rendering-method gl_compatibility --rendering-driver opengl3_angle"
    static let preferenceKey = "WVRSTS2ANGLECompatibility"
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["WVR_STS2_ANGLE_TRIAL"] == "1" ||
            UserDefaults.standard.bool(forKey: preferenceKey)
    }

    static func cachedSource(in documents: URL) -> URL {
        documents.appendingPathComponent("WindowsVR/CompatibilityAssets/ANGLE-914c97c116e0", isDirectory: true)
    }

    static func hasCachedAssets(in documents: URL) -> Bool {
        assets.allSatisfy { (try? checkedAsset(cachedSource(in: documents).appendingPathComponent($0.name), pin: $0)) != nil }
    }

    static func adoptInstalledProfile(available: Bool, defaults: UserDefaults = .standard) {
        guard available, defaults.object(forKey: preferenceKey) == nil else { return }
        defaults.set(true, forKey: preferenceKey)
    }

    /// Import only the pinned assets into an app-owned cache. Ordinary Play
    /// does not depend on a diagnostic process environment or its run folder.
    static func installProfile(source: URL, documents: URL, defaults: UserDefaults = .standard,
                               pins: [Asset] = assets) throws {
        try validatePins(pins)
        let source = try checkedDirectory(source, create: false)
        let inputs = try pins.map { ($0, try checkedAsset(source.appendingPathComponent($0.name), pin: $0)) }
        let cache = try checkedDirectory(cachedSource(in: documents), create: true)
        for (pin, data) in inputs {
            let file = cache.appendingPathComponent(pin.name)
            if FileManager.default.fileExists(atPath: file.path) ||
                (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) != nil {
                _ = try checkedAsset(file, pin: pin)
            } else {
                try data.write(to: file, options: .withoutOverwriting)
            }
        }
        defaults.set(true, forKey: preferenceKey)
    }

    static func launchArguments(appID: Int, enabled: Bool) -> String? {
        enabled && appID == 2868840 ? arguments : nil
    }

    /// The device-managed probe needs an 8 GiB virtual reservation. Scope the
    /// comparison to this explicit trial and preserve an explicit caller value.
    static func environment(appID: Int, enabled: Bool, base: [String: String]) -> [String: String] {
        guard enabled, appID == 2868840 else { return base }
        var result = base
        if result["DOTNET_GCRegionRange"] == nil,
           ProcessInfo.processInfo.environment["DOTNET_GCRegionRange"] == nil {
            result["DOTNET_GCRegionRange"] = "200000000"
        }
        return result
    }

    static func sourceDirectory(documents: URL, runID: String?) throws -> URL {
        if let runID {
            guard UUID(uuidString: runID) != nil else { throw Failure.unsafePath }
            return documents.appendingPathComponent("WindowsVR/ProbeRuns/\(runID)/angle", isDirectory: true)
        }
        if hasCachedAssets(in: documents) { return cachedSource(in: documents) }
        return documents.appendingPathComponent("WindowsVR/CompatibilityProbes/angle", isDirectory: true)
    }

    static func ledger(in documents: URL) -> URL {
        documents.appendingPathComponent("WindowsVR/CompatibilityTrials/Steam2868840", isDirectory: true)
    }

    private static func validatePins(_ pins: [Asset]) throws {
        guard !pins.isEmpty, pins.count <= assets.count, Set(pins.map(\.name)).count == pins.count,
              pins.allSatisfy({ pin in assets.contains { $0.name == pin.name } && pin.sha256.count == 64 &&
                pin.sha256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }) else {
            throw Failure.invalidJournal
        }
    }

    enum Failure: LocalizedError {
        case unsafePath, invalidAsset(String), conflict(String), invalidJournal
        var errorDescription: String? {
            switch self {
            case .unsafePath: "The ANGLE trial folder is unsafe."
            case .invalidAsset(let name): "The ANGLE trial needs the verified x64 asset: \(name)."
            case .conflict(let name): "The ANGLE trial preserved a conflicting or changed file: \(name)."
            case .invalidJournal: "The ANGLE trial ownership journal is invalid; files were preserved."
            }
        }
    }

    private struct Owned: Codable {
        let asset: Asset
        let inode: UInt64
        let device: UInt64
    }
    private struct Journal: Codable {
        var schemaVersion = 1
        let transaction: UUID
        let gameRelativePath: String
        let files: [Owned]
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func regularData(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= 32 * 1_024 * 1_024 else { throw Failure.unsafePath }
        return try Data(contentsOf: url)
    }

    private static func checkedAsset(_ url: URL, pin: Asset) throws -> Data {
        let data = try regularData(url)
        guard data.count >= 64, data[0] == 0x4d, data[1] == 0x5a, digest(data) == pin.sha256 else {
            throw Failure.invalidAsset(pin.name)
        }
        let offset = (0..<4).reduce(0) { $0 | (Int(data[60 + $1]) << (8 * $1)) }
        guard offset >= 64, offset <= data.count - 6,
              Array(data[offset..<offset + 4]) == [0x50, 0x45, 0, 0],
              data[offset + 4] == 0x64, data[offset + 5] == 0x86 else { throw Failure.invalidAsset(pin.name) }
        return data
    }

    private static func checkedDirectory(_ url: URL, create: Bool) throws -> URL {
        let path = url.standardizedFileURL
        guard path == path.resolvingSymlinksInPath() else { throw Failure.unsafePath }
        if create { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let values = try path.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw Failure.unsafePath }
        return path
    }

    private static func gameFolder(drive: URL, relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." &&
            !$0.contains("\\") && !$0.contains(":") && !$0.utf8.contains(0) }) else { throw Failure.unsafePath }
        let root = drive.resolvingSymlinksInPath().standardizedFileURL
        let folder = root.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
        guard folder.path.hasPrefix(root.path + "/") else { throw Failure.unsafePath }
        return try checkedDirectory(folder, create: false)
    }

    private static func identity(_ url: URL) throws -> (UInt64, UInt64) {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let inode = values[.systemFileNumber] as? NSNumber,
              let device = values[.systemNumber] as? NSNumber else { throw Failure.unsafePath }
        return (inode.uint64Value, device.uint64Value)
    }

    /// Publish through an exclusive hard link after writing an ownership journal.
    /// Recovery recognizes the exact created inode, including a crash between
    /// publication and return. An existing game file is never overwritten.
    static func prepare(source: URL, drive: URL, gameRelativePath: String, ledger: URL,
                        pins: [Asset] = assets) throws {
        try validatePins(pins)
        try recover(drive: drive, ledger: ledger, pins: pins)
        let folder = try gameFolder(drive: drive, relative: gameRelativePath)
        let source = try checkedDirectory(source.resolvingSymlinksInPath(), create: false)
        let ledger = try checkedDirectory(ledger, create: true)
        let inputs = try pins.map { ($0, try checkedAsset(source.appendingPathComponent($0.name), pin: $0)) }
        let fm = FileManager.default
        var needed: [(Asset, Data)] = []
        for (pin, data) in inputs {
            let destination = folder.appendingPathComponent(pin.name)
            if fm.fileExists(atPath: destination.path) || (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil {
                guard (try? checkedAsset(destination, pin: pin)) != nil else { throw Failure.conflict(pin.name) }
            } else { needed.append((pin, data)) }
        }
        if needed.isEmpty { return }
        let transaction = UUID()
        let staging = try checkedDirectory(ledger.appendingPathComponent(transaction.uuidString), create: true)
        var journalPublished = false
        do {
            var files: [Owned] = []
            for (pin, data) in needed {
                let staged = staging.appendingPathComponent(pin.name)
                try data.write(to: staged, options: .withoutOverwriting)
                let (inode, device) = try identity(staged)
                files.append(Owned(asset: pin, inode: inode, device: device))
            }
            let journal = Journal(transaction: transaction, gameRelativePath: gameRelativePath, files: files)
            try JSONEncoder().encode(journal).write(to: ledger.appendingPathComponent("journal.json"), options: .atomic)
            journalPublished = true
            for file in files {
                let result = staging.appendingPathComponent(file.asset.name).path.withCString { staged in
                    folder.appendingPathComponent(file.asset.name).path.withCString { link(staged, $0) }
                }
                guard result == 0 else { throw Failure.conflict(file.asset.name) }
            }
        } catch {
            if journalPublished { try? recover(drive: drive, ledger: ledger, pins: pins) }
            else { try? fm.removeItem(at: staging) }
            throw error
        }
    }

    /// Called only before a runtime session starts. A changed file or different
    /// inode is preserved and reported; hashes alone never confer ownership.
    static func recover(drive: URL, ledger: URL, pins: [Asset] = assets) throws {
        try validatePins(pins)
        let fm = FileManager.default
        let journalURL = ledger.appendingPathComponent("journal.json")
        guard fm.fileExists(atPath: journalURL.path) || (try? fm.destinationOfSymbolicLink(atPath: journalURL.path)) != nil else { return }
        let ledger = try checkedDirectory(ledger, create: false)
        let data = try regularData(journalURL)
        guard data.count <= 64 * 1_024,
              let journal = try? JSONDecoder().decode(Journal.self, from: data), journal.schemaVersion == 1,
              !journal.files.isEmpty, journal.files.count <= pins.count,
              Set(journal.files.map { $0.asset.name }).count == journal.files.count,
              journal.files.allSatisfy({ owned in pins.contains { $0.name == owned.asset.name && $0.sha256 == owned.asset.sha256 } }) else {
            throw Failure.invalidJournal
        }
        let folder = try gameFolder(drive: drive, relative: journal.gameRelativePath)
        for owned in journal.files {
            let path = folder.appendingPathComponent(owned.asset.name)
            if !fm.fileExists(atPath: path.path), (try? fm.destinationOfSymbolicLink(atPath: path.path)) == nil { continue }
            let (inode, device) = try identity(path)
            guard inode == owned.inode, device == owned.device,
                  (try? checkedAsset(path, pin: owned.asset)) != nil else { throw Failure.conflict(owned.asset.name) }
            try fm.removeItem(at: path)
        }
        let staging = ledger.appendingPathComponent(journal.transaction.uuidString)
        if fm.fileExists(atPath: staging.path) {
            _ = try checkedDirectory(staging, create: false)
            try fm.removeItem(at: staging)
        }
        try fm.removeItem(at: journalURL)
    }
}
