"""Execute trial deployment/recovery against real temporary filesystem objects."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AngleTrial(unittest.TestCase):
    def test_publication_ownership_conflicts_and_restart_recovery(self):
        harness = r'''
import Foundation
import CryptoKit
let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let drive = root.appendingPathComponent("drive")
let source = root.appendingPathComponent("source")
let game = drive.appendingPathComponent("library/common/Game")
let ledger = root.appendingPathComponent("ledger")
for path in [source, game] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
var data = Data(repeating: 0, count: 256)
data[0] = 0x4d; data[1] = 0x5a; data[60] = 128
data[128] = 0x50; data[129] = 0x45; data[132] = 0x64; data[133] = 0x86
let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
let pins = WindowsVRAngleTrial.assets.map { WindowsVRAngleTrial.Asset(name: $0.name, sha256: hash) }
for pin in pins { try data.write(to: source.appendingPathComponent(pin.name)) }
func prepare() throws { try WindowsVRAngleTrial.prepare(source: source, drive: drive, gameRelativePath: "library/common/Game", ledger: ledger, pins: pins) }
func recover() throws { try WindowsVRAngleTrial.recover(drive: drive, ledger: ledger, pins: pins) }
func expect(_ value: Bool) { assert(value) }
func mustThrow(_ body: () throws -> Void) {
    do { try body(); fatalError("Expected preservation/rejection") } catch {}
}
assert(WindowsVRAngleTrial.launchArguments(appID: 2868840, enabled: false) == nil)
assert(WindowsVRAngleTrial.launchArguments(appID: 123, enabled: true) == nil)
assert(WindowsVRAngleTrial.launchArguments(appID: 2868840, enabled: true)?.contains("opengl3_angle") == true)
assert(WindowsVRAngleTrial.environment(appID: 123, enabled: true, base: [:]).isEmpty)
assert(WindowsVRAngleTrial.environment(appID: 2868840, enabled: false, base: [:]).isEmpty)
assert(WindowsVRAngleTrial.environment(appID: 2868840, enabled: true,
    base: ["DOTNET_GCRegionRange": "400000000"])["DOTNET_GCRegionRange"] == "400000000")
let run = UUID().uuidString
expect(try WindowsVRAngleTrial.sourceDirectory(documents: root, runID: run).path ==
    root.appendingPathComponent("WindowsVR/ProbeRuns/\(run)/angle").path)
mustThrow { _ = try WindowsVRAngleTrial.sourceDirectory(documents: root, runID: "../../outside") }
let suite = "wvr-angle-contract-" + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
WindowsVRAngleTrial.adoptInstalledProfile(available: false, defaults: defaults)
assert(defaults.object(forKey: WindowsVRAngleTrial.preferenceKey) == nil)
WindowsVRAngleTrial.adoptInstalledProfile(available: true, defaults: defaults)
assert(defaults.bool(forKey: WindowsVRAngleTrial.preferenceKey))
defaults.set(false, forKey: WindowsVRAngleTrial.preferenceKey)
WindowsVRAngleTrial.adoptInstalledProfile(available: true, defaults: defaults)
assert(!defaults.bool(forKey: WindowsVRAngleTrial.preferenceKey))
let profileDocs = root.appendingPathComponent("profile-documents")
try WindowsVRAngleTrial.installProfile(source: source, documents: profileDocs, defaults: defaults, pins: pins)
assert(defaults.bool(forKey: WindowsVRAngleTrial.preferenceKey))
// Fixtures use test hashes: production cache detection must require the real pins.
assert(!WindowsVRAngleTrial.hasCachedAssets(in: profileDocs))
// A second install verifies existing cache files instead of overwriting them.
let cached = WindowsVRAngleTrial.cachedSource(in: profileDocs).appendingPathComponent(pins[0].name)
try Data([9, 8, 7]).write(to: cached)
defaults.set(false, forKey: WindowsVRAngleTrial.preferenceKey)
mustThrow { try WindowsVRAngleTrial.installProfile(source: source, documents: profileDocs, defaults: defaults, pins: pins) }
assert(!defaults.bool(forKey: WindowsVRAngleTrial.preferenceKey))
expect(try Data(contentsOf: cached) == Data([9, 8, 7]))
try prepare()
for pin in pins { expect(try Data(contentsOf: game.appendingPathComponent(pin.name)) == data) }
// Simulate restart after publication and after only one of two publications.
try fm.removeItem(at: game.appendingPathComponent(pins[0].name))
try recover()
for pin in pins { assert(!fm.fileExists(atPath: game.appendingPathComponent(pin.name).path)) }
try recover()
// Borrow a matching original without taking ownership; remove only our second DLL.
let original = game.appendingPathComponent(pins[0].name)
try data.write(to: original)
try prepare(); try recover()
expect(try Data(contentsOf: original) == data)
assert(!fm.fileExists(atPath: game.appendingPathComponent(pins[1].name).path))
// Conflicting original and even dangling symlinks are preserved.
try Data([1, 2, 3]).write(to: original)
mustThrow { try prepare() }
expect(try Data(contentsOf: original) == Data([1, 2, 3]))
try fm.removeItem(at: original)
try fm.createSymbolicLink(atPath: original.path, withDestinationPath: root.appendingPathComponent("missing").path)
mustThrow { try prepare() }
assert((try? fm.destinationOfSymbolicLink(atPath: original.path)) != nil)
try fm.removeItem(at: original)
// A later replacement with identical bytes is still a different user's inode.
try prepare()
try fm.removeItem(at: original); try data.write(to: original)
mustThrow { try recover() }
expect(try Data(contentsOf: original) == data)
// Recovery may remove an absent file, and can finish the remaining owned entry.
try fm.removeItem(at: original); try recover()
// In-place changes to an owned file are also preserved.
try prepare(); try Data([4, 5, 6]).write(to: original)
mustThrow { try recover() }
expect(try Data(contentsOf: original) == Data([4, 5, 6]))
try fm.removeItem(at: original); try recover()
// Corrupt journals and a symlinked destination cannot redirect cleanup/writes.
try fm.createDirectory(at: ledger, withIntermediateDirectories: true)
try Data("{}".utf8).write(to: ledger.appendingPathComponent("journal.json"))
mustThrow { try recover() }
try fm.removeItem(at: ledger.appendingPathComponent("journal.json"))
let external = root.appendingPathComponent("external")
try fm.createDirectory(at: external, withIntermediateDirectories: true)
try fm.removeItem(at: game)
try fm.createSymbolicLink(atPath: game.path, withDestinationPath: external.path)
mustThrow { try prepare() }
expect(try fm.contentsOfDirectory(atPath: external.path).isEmpty)
print("PASS: scoped trial, exclusive publication, interrupted publication, borrowed files, conflicts, changed inodes, changed bytes, malformed journals and symlink confinement")
'''
        with tempfile.TemporaryDirectory(prefix="wvr-angle-trial-") as work:
            work = Path(work)
            (work / "main.swift").write_text(harness)
            subprocess.run(["xcrun", "swiftc", "-swift-version", "6",
                            str(ROOT / "Sources/WindowsVRAngleTrial.swift"), str(work / "main.swift"),
                            "-o", str(work / "probe")], check=True)
            subprocess.run([str(work / "probe"), str(work / "files")], check=True)


if __name__ == "__main__":
    unittest.main()
