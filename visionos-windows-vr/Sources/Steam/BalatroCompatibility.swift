import Foundation
import CryptoKit

/// Balatro's stock LuaJIT 2.0 requires allocations below 2 GiB, inside the
/// visionOS host's page zero. GC64 keeps the Lua 5.1 API with usable addresses.
enum BalatroCompatibility {
    static let appID = 2379780
    static let originalSHA256 = "d0039528d0c48acf9e4b93e39f929ecd8def2b08c429971b809d8751aae49fb2"
    static let runtimeSHA256 = "a77addc0c78fb0665bae6b7894379999dd9458633a990326982cdfcadf74d086"
    // User-installed Microsoft redistributable shipped with Bigscreen's
    // Chromium plugin. It is reused locally and is never bundled in this app.
    static let compilerSHA256 = "7353f25dc5cf84d09894e3e0461cef0e56799adbc617fce37620ca67240b547d"

    static func environment(appID: Int, base: [String: String]) -> [String: String] {
        guard appID == Self.appID else { return base }
        var result = base
        for key in ["LOVE_GRAPHICS_USE_OPENGLES", "SDL_OPENGL_ES_DRIVER"]
            where result[key] == nil && ProcessInfo.processInfo.environment[key] == nil {
            result[key] = "1"
        }
        return result
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func regularData(_ file: URL) throws -> Data {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, (1...33_554_432).contains(size) else {
            throw DockError.message("Balatro's compatibility file is missing or unsafe: \(file.lastPathComponent).")
        }
        return try Data(contentsOf: file)
    }

    static func prepare(game: DockGame, drive: URL, resources: URL? = Bundle.main.resourceURL) throws {
        guard game.id == appID else { return }
        try MadeiraDock.validate(game, drive: drive)
        let folder = drive.appendingPathComponent(game.library + "/common/" + game.installDir).standardizedFileURL
        guard folder == folder.resolvingSymlinksInPath(),
              folder.path.hasPrefix(drive.resolvingSymlinksInPath().path + "/"),
              let resources else {
            throw DockError.message("Balatro's compatibility folder is unavailable or unsafe.")
        }
        let source = resources.appendingPathComponent("GameCompatibility/Balatro/lua51.dll")
        let replacement = try regularData(source)
        guard hash(replacement) == runtimeSHA256 else {
            throw DockError.message("Build Balatro's verified GC64 compatibility runtime before launching.")
        }
        let target = folder.appendingPathComponent("lua51.dll")
        let existing = try regularData(target)
        if hash(existing) != runtimeSHA256 {
            guard hash(existing) == originalSHA256 else {
                throw DockError.message("Balatro's Lua runtime has been modified. Its files were preserved; update or repair the game before retrying.")
            }
            let backup = folder.appendingPathComponent("lua51.dll.winevision-original")
            if FileManager.default.fileExists(atPath: backup.path) {
                guard hash(try regularData(backup)) == originalSHA256 else {
                    throw DockError.message("Balatro's original-runtime backup differs; its files were preserved.")
                }
            } else {
                try existing.write(to: backup, options: .withoutOverwriting)
            }
            try replacement.write(to: target, options: .atomic)
        }

        // SDL loads these by name beside the game. Preserve any unrecognized file.
        for pin in WindowsVRAngleTrial.assets {
            let data = try regularData(resources.appendingPathComponent("ANGLECompatibility/" + pin.name))
            guard hash(data) == pin.sha256 else { throw DockError.message("Balatro's ANGLE renderer failed verification.") }
            let file = folder.appendingPathComponent(pin.name)
            if FileManager.default.fileExists(atPath: file.path) {
                guard hash(try regularData(file)) == pin.sha256 else {
                    throw DockError.message("Balatro has a different \(pin.name); its renderer was preserved.")
                }
            } else { try data.write(to: file, options: .withoutOverwriting) }
        }
        try prepareShaderCompiler(folder: folder, drive: drive, library: game.library)
        try prepareComputerName(prefix: drive.deletingLastPathComponent())
    }

    private static func prepareShaderCompiler(folder: URL, drive: URL, library: String) throws {
        let target = folder.appendingPathComponent("d3dcompiler_47.dll")
        if FileManager.default.fileExists(atPath: target.path) {
            guard hash(try regularData(target)) == compilerSHA256 else {
                throw DockError.message("Balatro's shader compiler differs from the verified compatibility version; its file was preserved.")
            }
            return
        }
        let source = drive.appendingPathComponent(library + "/common/Bigscreen/Bigscreen_Data/Plugins/x86_64/VuplexWebViewChromium/d3dcompiler_47.dll")
        guard source.standardizedFileURL == source.resolvingSymlinksInPath(),
              source.path.hasPrefix(drive.resolvingSymlinksInPath().path + "/"),
              let compiler = try? regularData(source), hash(compiler) == compilerSHA256 else {
            throw DockError.message("Balatro needs the verified Microsoft shader compiler. Install Bigscreen's Windows files or copy its d3dcompiler_47.dll beside Balatro.exe before retrying.")
        }
        try compiler.write(to: target, options: .withoutOverwriting)
    }

    /// Wineboot normally creates this key. Without it LookupAccountSidW cannot
    /// resolve the local token, and PhysFS cannot obtain its user directory.
    static func computerNameRegistry(_ text: String) throws -> String {
        guard text.hasPrefix("WINE REGISTRY Version 2") else {
            throw DockError.message("The Wine prefix registry is invalid.")
        }
        let lines = text.components(separatedBy: "\n")
        var controlSet = "ControlSet001"
        if let select = lines.firstIndex(where: { $0.hasPrefix("[System\\\\Select]") }) {
            for line in lines.dropFirst(select + 1).prefix(while: { !$0.hasPrefix("[") }) {
                if line.hasPrefix("\"Current\"=dword:"), let number = UInt32(line.dropFirst(16), radix: 16), (1...999).contains(number) {
                    controlSet = String(format: "ControlSet%03u", number)
                }
            }
        }
        let root = "System\\\\\(controlSet)\\\\Control\\\\ComputerName\\\\"
        if lines.contains(where: { $0.lowercased().hasPrefix("[\(root)ActiveComputerName]".lowercased()) }) { return text }
        guard let start = lines.firstIndex(where: { $0.lowercased().hasPrefix("[\(root)ComputerName]".lowercased()) }),
              let name = lines.dropFirst(start + 1).prefix(while: { !$0.hasPrefix("[") })
                .first(where: { $0.hasPrefix("\"ComputerName\"=\"") }),
              name.hasSuffix("\""), name.count <= 64 else {
            throw DockError.message("The Wine prefix has no configured computer name.")
        }
        return text + "\n[\(root)ActiveComputerName]\n\(name)\n"
    }

    private static func prepareComputerName(prefix: URL) throws {
        let file = prefix.appendingPathComponent("system.reg")
        guard file.standardizedFileURL == file.resolvingSymlinksInPath() else {
            throw DockError.message("The Wine prefix registry path is unsafe.")
        }
        let original = try String(contentsOf: file, encoding: .utf8)
        let updated = try computerNameRegistry(original)
        if updated != original { try updated.write(to: file, atomically: true, encoding: .utf8) }
    }
}
