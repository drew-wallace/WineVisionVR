"""Exercise removal of the retired adapter without altering genuine game updates."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class VegasCompatibilityTests(unittest.TestCase):
    def test_retired_adapter_cleanup(self):
        stubs = '''
import Foundation
struct DockGame { let id: Int; let library: String; let installDir: String }
enum DockError: Error { case message(String) }
enum MadeiraDock { static func validate(_ game: DockGame, drive: URL) throws {} }
func wine_process_is_running() -> Int32 { 0 }
func wineserver_is_running() -> Int32 { 0 }
'''
        harness = r'''
import Foundation
@main struct Probe {
    static func main() throws {
        typealias V = VegasInfiniteCompatibility
        let fm = FileManager.default
        let temp = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = Data("original Valve API fixture".utf8)
        let originalHash = V.digest(original)
        let package = temp.appendingPathComponent("package")
        try fm.createDirectory(at: package, withIntermediateDirectories: true)
        var files: [String: Data] = ["steam_api64.dll": Data("avatar proxy fixture".utf8),
            "vcruntime140_1.dll": Data("C++ runtime fixture".utf8), "sensapi.dll": Data("network presence fixture".utf8)]
        func publish() throws {
            for (name, data) in files { try data.write(to: package.appendingPathComponent(name)) }
            let p = V.Package(schemaVersion: 1, originalSHA256: originalHash, filesSHA256: files.mapValues(V.digest))
            try JSONEncoder().encode(p).write(to: package.appendingPathComponent("package.json"))
        }
        func game(_ name: String) throws -> (URL, URL) {
            let root = temp.appendingPathComponent(name)
            let plugins = root.appendingPathComponent("PokerStarsVR_Data/Plugins/x86_64")
            try fm.createDirectory(at: plugins, withIntermediateDirectories: true)
            let entry = plugins.appendingPathComponent("steam_api64.dll")
            try original.write(to: entry)
            return (root, entry)
        }
        func rejected(_ operation: () throws -> Void) {
            do { try operation(); fatalError("accepted invalid input") } catch {}
        }
        func legacy(_ name: String) throws -> (URL, URL) {
            let (root, entry) = try game(name)
            try files["steam_api64.dll"]!.write(to: entry)
            for folder in [root, entry.deletingLastPathComponent()] {
                try original.write(to: folder.appendingPathComponent("wvr_steam_api64_original.dll"))
            }
            for name in ["vcruntime140_1.dll", "sensapi.dll"] {
                try files[name]!.write(to: root.appendingPathComponent(name))
            }
            try Data(contentsOf: package.appendingPathComponent("package.json"))
                .write(to: root.appendingPathComponent(".winevision-vegas-compatibility.json"))
            return (root, entry)
        }
        func restore(_ root: URL) throws {
            try V.restore(gameFolder: root, packageFolder: package, expectedOriginalSHA256: originalHash)
        }
        try publish()
        let (root, entry) = try legacy("game")
        let unrelated = root.appendingPathComponent("keep-user-file.txt")
        try original.write(to: unrelated)
        try restore(root)
        assert((try! Data(contentsOf: entry)) == original)
        for path in ["wvr_steam_api64_original.dll", "PokerStarsVR_Data/Plugins/x86_64/wvr_steam_api64_original.dll",
                     "vcruntime140_1.dll", "sensapi.dll", ".winevision-vegas-compatibility.json"] {
            assert(!fm.fileExists(atPath: root.appendingPathComponent(path).path))
        }
        assert((try! Data(contentsOf: unrelated)) == original)
        try restore(root)
        // A Steam update's genuine DLL is never replaced by our older backup.
        let newer = Data("newer genuine Valve API fixture".utf8)
        let (updated, updatedEntry) = try legacy("updated")
        try newer.write(to: updatedEntry)
        try restore(updated)
        assert((try! Data(contentsOf: updatedEntry)) == newer)
        // Unrecognized libraries and backups stay intact.
        let (conflict, conflictEntry) = try legacy("conflict")
        try original.write(to: conflictEntry)
        try newer.write(to: conflict.appendingPathComponent("sensapi.dll"))
        try newer.write(to: conflict.appendingPathComponent("wvr_steam_api64_original.dll"))
        try restore(conflict)
        assert((try! Data(contentsOf: conflict.appendingPathComponent("sensapi.dll"))) == newer)
        assert((try! Data(contentsOf: conflict.appendingPathComponent("wvr_steam_api64_original.dll"))) == newer)
        let (missing, missingEntry) = try legacy("missing")
        for folder in [missing, missingEntry.deletingLastPathComponent()] {
            try fm.removeItem(at: folder.appendingPathComponent("wvr_steam_api64_original.dll"))
        }
        rejected { try restore(missing) }
        assert((try! Data(contentsOf: missingEntry)) == files["steam_api64.dll"]!)
        let (rollback, rollbackEntry) = try legacy("rollback")
        rejected {
            try V.restore(gameFolder: rollback, packageFolder: package, expectedOriginalSHA256: originalHash,
                writeFile: { data, url in
                    try Data("partial write".utf8).write(to: url)
                    throw CocoaError(.fileWriteOutOfSpace)
                })
        }
        assert((try! Data(contentsOf: rollbackEntry)) == files["steam_api64.dll"]!)
        assert(fm.fileExists(atPath: rollback.appendingPathComponent("wvr_steam_api64_original.dll").path))
        let (unsafe, unsafeEntry) = try legacy("unsafe")
        try fm.removeItem(at: unsafe.appendingPathComponent("sensapi.dll"))
        try fm.createSymbolicLink(at: unsafe.appendingPathComponent("sensapi.dll"), withDestinationURL: entry)
        rejected { try restore(unsafe) }
        assert((try! Data(contentsOf: unsafeEntry)) == files["steam_api64.dll"]!)
        let (corrupt, corruptEntry) = try legacy("corrupt")
        try newer.write(to: package.appendingPathComponent("steam_api64.dll"))
        rejected { try restore(corrupt) }
        assert((try! Data(contentsOf: corruptEntry)) == files["steam_api64.dll"]!)
        print("PASS: retired adapter removal, genuine library restoration, repeat launch, newer game and user file preservation, missing backup/corrupt package/symlink rejection and failed-write rollback")
    }
}
'''
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / 'Stubs.swift').write_text(stubs)
            (folder / 'Probe.swift').write_text(harness)
            subprocess.run(['swiftc', str(folder / 'Stubs.swift'),
                            str(ROOT / 'Sources/Steam/VegasInfiniteCompatibility.swift'),
                            str(folder / 'Probe.swift'), '-o', str(folder / 'probe')], check=True, capture_output=True)
            subprocess.run([str(folder / 'probe'), str(folder)], check=True, capture_output=True, timeout=20)


if __name__ == '__main__':
    unittest.main()
