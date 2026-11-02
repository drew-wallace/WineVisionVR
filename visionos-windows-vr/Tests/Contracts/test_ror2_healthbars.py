"""Run the production repair against real ZIPs and disposable game/cache folders."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/Steam"
RECIPE = ROOT / "Resources/GameCompatibility/RiskOfRain2/healthbars.json"

STUBS = """
import Foundation
struct DockGame { let id: Int; let library: String; let installDir: String }
enum MadeiraDock { static func validate(_ game: DockGame, drive: URL) throws {} }
enum LaunchLogFile { static func append(_ level: String, _ message: String) {} }
func wine_process_is_running() -> Int32 { 0 }
func wineserver_is_running() -> Int32 { 0 }
"""

HARNESS = r'''
import Foundation
typealias Repair = RiskOfRain2HealthBarRepair
actor Downloads {
    var calls = 0
    let packages: URL
    init(_ packages: URL) { self.packages = packages }
    func get(_ package: Repair.Package) throws -> Data {
        calls += 1
        return try Data(contentsOf: packages.appendingPathComponent(package.id + ".zip"))
    }
}
final class Session: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    func start() { lock.lock(); running = true; lock.unlock() }
    func canModify() -> Bool { lock.lock(); defer { lock.unlock() }; return !running }
}
enum TestFailure: Error { case offline }
func expect(_ value: Bool) { precondition(value) }
@MainActor func rejects(_ action: () async throws -> Void) async {
    do { try await action(); fatalError("Expected failure") } catch {}
}
@main struct Probe {
    static func main() async throws {
        let fm = FileManager.default
        let recipeURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let packages = URL(fileURLWithPath: CommandLine.arguments[2])
        let root = URL(fileURLWithPath: CommandLine.arguments[3]).resolvingSymlinksInPath()
        let recipe = try JSONDecoder().decode(Repair.Recipe.self, from: Data(contentsOf: recipeURL))
        try recipe.validate()
        let repair = Repair()
        let network = Downloads(packages)
        let drive = root.appendingPathComponent("drive")
        let game = drive.appendingPathComponent("Steam/steamapps/common/Risk of Rain 2")
        let cache = root.appendingPathComponent("cache")
        let config = game.appendingPathComponent("BepInEx/config/BepInEx.cfg")
        func fresh() throws {
            if fm.fileExists(atPath: game.path) { try fm.removeItem(at: game) }
            try fm.createDirectory(at: game, withIntermediateDirectories: true)
            try Data("game executable".utf8).write(to: game.appendingPathComponent("Risk of Rain 2.exe"))
        }
        func run(cache chosenCache: URL? = nil, appID: Int = Repair.appID,
                 relative: String = "Steam/steamapps/common/Risk of Rain 2",
                 canModify: @Sendable () -> Bool = { true },
                 download: (@Sendable (Repair.Package) async throws -> Data)? = nil) async throws {
            try await repair.prepare(appID: appID, drive: drive, gameRelativePath: relative,
                cache: chosenCache ?? cache, recipe: recipe, canModify: canModify,
                download: download ?? { try await network.get($0) })
        }
        func offline(_ package: Repair.Package) async throws -> Data { throw TestFailure.offline }
        func verified() throws {
            for asset in recipe.assets {
                let url = game.appendingPathComponent(asset.path)
                let bytes = try Data(contentsOf: url)
                expect(bytes.count == asset.bytes && Repair.digest(bytes) == asset.sha256)
                let attributes = try fm.attributesOfItem(atPath: url.path)
                expect((attributes[.referenceCount] as? Int) == 1)
            }
            expect(try Data(contentsOf: config) == Repair.configuration(Data(contentsOf: config)))
            expect(try fm.contentsOfDirectory(atPath: game.path).allSatisfy { !$0.hasPrefix(".winevision-healthbars-") })
        }
        // An unrelated title cannot create folders, even with a bad path and no runtime.
        try await run(appID: 123, relative: "../../outside", canModify: { false })
        expect(!fm.fileExists(atPath: root.path))
        try fresh()
        // Offline/corrupt package failure leaves the game unchanged.
        await rejects { try await run(download: offline) }
        expect(try fm.contentsOfDirectory(atPath: game.path).count == 1)
        await rejects { try await run(download: { _ in Data("bad archive".utf8) }) }
        expect(try fm.contentsOfDirectory(atPath: game.path).count == 1)
        await rejects { try await run(relative: "../escape") }
        // Clean installation verifies every file and includes the required config.
        try await run(); try verified()
        expect(await network.calls == recipe.packages.count)
        let loader = game.appendingPathComponent("winhttp.dll")
        let inode = try fm.attributesOfItem(atPath: loader.path)[.systemFileNumber] as! NSNumber
        let configDate = try fm.attributesOfItem(atPath: config.path)[.modificationDate] as! Date
        try await run(download: offline); try verified()
        expect(try fm.attributesOfItem(atPath: loader.path)[.systemFileNumber] as! NSNumber == inode)
        expect(try fm.attributesOfItem(atPath: config.path)[.modificationDate] as! Date == configDate)
        // Existing manual installations seed a new cache with no network traffic.
        let adoptedCache = root.appendingPathComponent("adopted-cache")
        let original = Data("\u{feff}# keep me\r\n[Preloader]\r\nApplyRuntimePatches = true\t\r\n[Other]\r\nCustom = yes\r\n".utf8)
        try original.write(to: config)
        let unrelated = game.appendingPathComponent("BepInEx/plugins/OtherMod.dll")
        try Data([7, 8, 9]).write(to: unrelated)
        try await run(cache: adoptedCache, download: offline)
        expect(try Data(contentsOf: config) == Repair.configuration(original))
        expect(try Data(contentsOf: adoptedCache.appendingPathComponent("ConfigBackups/" + Repair.digest(original) + ".cfg")) == original)
        expect(try Data(contentsOf: unrelated) == Data([7, 8, 9]))
        // Steam uninstall can delete every mod file; persistent cache restores all offline.
        try fresh()
        try await run(cache: adoptedCache, download: offline); try verified()
        // A partial reinstall is healed while matching files keep their identity.
        try fm.removeItem(at: game.appendingPathComponent(recipe.assets.last!.path))
        let preserved = try fm.attributesOfItem(atPath: loader.path)[.systemFileNumber] as! NSNumber
        try await run(download: offline); try verified()
        expect(try fm.attributesOfItem(atPath: loader.path)[.systemFileNumber] as! NSNumber == preserved)
        // Never replace another loader or a changed plugin, nor partially publish around it.
        try fresh(); try Data([1, 2, 3]).write(to: loader)
        await rejects { try await run() }
        expect(try Data(contentsOf: loader) == Data([1, 2, 3]))
        expect(!fm.fileExists(atPath: game.appendingPathComponent("BepInEx").path))
        try fresh(); try await run(download: offline)
        let plugin = game.appendingPathComponent(recipe.assets.last!.path)
        try Data([9]).write(to: plugin)
        await rejects { try await run() }
        expect(try Data(contentsOf: plugin) == Data([9]))
        // Case variants and symlinked folders must not redirect installation.
        try fresh(); try Data([5]).write(to: game.appendingPathComponent("WINHTTP.DLL"))
        await rejects { try await run() }
        expect(!fm.fileExists(atPath: game.appendingPathComponent("BepInEx").path))
        try fresh()
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: game.appendingPathComponent("BepInEx"), withDestinationURL: outside)
        await rejects { try await run() }
        expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        // A runtime starting while fetching prevents publication.
        try fresh()
        let active = Session()
        await rejects {
            try await run(cache: root.appendingPathComponent("active-cache"), canModify: { active.canModify() }, download: {
                active.start(); return try await network.get($0)
            })
        }
        expect(try fm.contentsOfDirectory(atPath: game.path).count == 1)
        // Cancellation after a download also leaves all game files untouched.
        let cancelled = Task {
            try await run(cache: root.appendingPathComponent("cancelled-cache"), download: {
                let bytes = try await network.get($0)
                withUnsafeCurrentTask { $0?.cancel() }
                return bytes
            })
        }
        await rejects { try await cancelled.value }
        expect(try fm.contentsOfDirectory(atPath: game.path).count == 1)
        // Ambiguous configuration never silently changes the wrong section/key.
        for invalid in ["[Preloader]\nApplyRuntimePatches = true\nApplyRuntimePatches = false\n",
                        "[Preloader]\n[Preloader]\n", "[Preloader]\nApplyRuntimePatches = maybe\n"] {
            do { _ = try Repair.configuration(Data(invalid.utf8)); fatalError("Expected config rejection") } catch {}
        }
        print("PASS: clean install, repeat launch, manual adoption, offline reinstall, partial repair, config preservation, conflicts, symlinks, cancellation and runtime exclusion")
    }
}
'''


class HealthBarRepair(unittest.TestCase):
    def test_install_launch_reinstall_and_preservation(self):
        with tempfile.TemporaryDirectory(prefix="wvr-healthbars-") as temp:
            work = Path(temp)
            packages, assets = [], []
            paths = [("loader", "winhttp.dll"),
                     ("loader", "BepInEx/core/BepInEx.dll"),
                     ("bars", "BepInEx/plugins/MetalSafeBars/MetalSafeBars.dll"),
                     ("json", "BepInEx/core/Newtonsoft.Json.dll")]
            for package_id in ("loader", "bars", "json"):
                archive = work / (package_id + ".zip")
                with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
                    for owner, path in paths:
                        if owner != package_id:
                            continue
                        data = ("verified test payload " + path).encode()
                        member = "package/" + path
                        z.writestr(member, data)
                        assets.append(dict(package=owner, member=member, path=path,
                                           bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
                data = archive.read_bytes()
                packages.append(dict(id=package_id, url="https://thunderstore.io/" + package_id,
                                     bytes=len(data), sha256=hashlib.sha256(data).hexdigest()))
            recipe = dict(schemaVersion=1, steamAppID=632360, revision="healthbars-test", packages=packages, assets=assets)
            (work / "recipe.json").write_text(json.dumps(recipe))
            runtime = (SOURCE / "SteamRuntime.swift").read_text().split(
                "#if canImport(CryptoKit)\nprivate final class SteamRuntimeRedirects")[0]
            (work / "Runtime.swift").write_text(runtime)
            (work / "Stubs.swift").write_text(STUBS)
            (work / "Probe.swift").write_text(HARNESS)
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                            str(work / "Runtime.swift"), str(work / "Stubs.swift"),
                            str(SOURCE / "RiskOfRain2HealthBarRepair.swift"), str(work / "Probe.swift"),
                            "-o", str(work / "probe")], check=True)
            subprocess.run([str(work / "probe"), str(work / "recipe.json"), str(work), str(work / "files")], check=True)

    def test_shipped_recipe_and_entry_points(self):
        recipe = json.loads(RECIPE.read_text())
        self.assertEqual(recipe["steamAppID"], 632360)
        self.assertEqual(len(recipe["assets"]), 25)
        by_path = {a["path"]: a for a in recipe["assets"]}
        self.assertEqual(by_path["BepInEx/plugins/MetalSafeBars/MetalSafeBars.dll"]["sha256"],
                         "96f12258e4ed6c620b74048881cdf021d8198fe48a55380ee70e79d0c064a1c6")
        self.assertIn("BepInEx/core/Newtonsoft.Json.dll", by_path)
        for source in (ROOT / "Sources/LauncherModel.swift", SOURCE / "SteamLibraryModel.swift"):
            self.assertIn("try await RiskOfRain2HealthBarRepair.prepare(game:", source.read_text())
        for spec in (ROOT / "project.yml", ROOT / "project.prebuilt.yml"):
            self.assertIn("path: Resources/GameCompatibility", spec.read_text())


if __name__ == "__main__":
    unittest.main()
