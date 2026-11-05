import Foundation

struct DockGame { let id: Int; let library: String; let installDir: String }
enum MadeiraDock { static func validate(_ game: DockGame, drive: URL) throws {} }

@main struct Probe {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let plugins = root.appendingPathComponent("game/Bigscreen_Data/Plugins/x86_64", isDirectory: true)
        let package = root.appendingPathComponent("package", isDirectory: true)
        try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        let original = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        precondition(BigscreenVideoCompatibility.digest(original) == BigscreenVideoCompatibility.originalSHA256)
        let proxy = Data("test-proxy".utf8), decoder = Data("test-decoder".utf8)
        try proxy.write(to: package.appendingPathComponent("BigSoup.dll"))
        try decoder.write(to: package.appendingPathComponent("amfrt64.dll"))
        let manifest = BigscreenVideoCompatibility.Package(schemaVersion: 1, originalSHA256: BigscreenVideoCompatibility.originalSHA256,
            filesSHA256: ["BigSoup.dll": BigscreenVideoCompatibility.digest(proxy), "amfrt64.dll": BigscreenVideoCompatibility.digest(decoder)])
        try JSONEncoder().encode(manifest).write(to: package.appendingPathComponent("package.json"))
        try original.write(to: plugins.appendingPathComponent("BigSoup.dll"))
        func install() throws { try BigscreenVideoCompatibility.install(gameFolder: root.appendingPathComponent("game"), packageFolder: package) }
        func expect(_ value: Data, _ expected: Data) { precondition(value == expected) }
        func destination(_ name: String) -> URL { (name == "BigSoup.dll" ? plugins : root.appendingPathComponent("game")).appendingPathComponent(name) }
        func contents(_ name: String) throws -> Data { try Data(contentsOf: destination(name)) }
        try install()
        expect(try contents("BigSoup.dll"), proxy)
        expect(try contents("wvr_bigsoup_original.dll"), original)
        expect(try contents("amfrt64.dll"), decoder)
        try install()
        let custom = Data("user file".utf8)
        try custom.write(to: destination("wvr_bigsoup_original.dll"))
        do { try install(); preconditionFailure("conflicting backup accepted") }
        catch BigscreenVideoCompatibility.Failure.conflict { }
        expect(try contents("wvr_bigsoup_original.dll"), custom)
        try original.write(to: destination("wvr_bigsoup_original.dll"))
        try custom.write(to: destination("amfrt64.dll"))
        do { try install(); preconditionFailure("conflicting decoder accepted") }
        catch BigscreenVideoCompatibility.Failure.conflict { }
        expect(try contents("amfrt64.dll"), custom)
        try decoder.write(to: destination("amfrt64.dll"))
        try custom.write(to: plugins.appendingPathComponent("BigSoup.dll"))
        do { try install(); preconditionFailure("unknown game accepted") }
        catch BigscreenVideoCompatibility.Failure.unsupportedGame { }
        expect(try contents("BigSoup.dll"), custom)
        try proxy.write(to: plugins.appendingPathComponent("BigSoup.dll"))
        try custom.write(to: package.appendingPathComponent("amfrt64.dll"))
        do { try install(); preconditionFailure("tampered package accepted") }
        catch BigscreenVideoCompatibility.Failure.invalidPackage { }
        expect(try contents("BigSoup.dll"), proxy)
        print("BIGSCREEN VIDEO INSTALLER CHECKS PASSED: original preservation, repeat, conflicts, unknown revisions, package integrity")
    }
}
