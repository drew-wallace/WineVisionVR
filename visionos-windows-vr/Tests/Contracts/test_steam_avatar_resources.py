"""Exercise the production Steam resource unpacker and missing-file repair."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]


class SteamAvatarResourcesTests(unittest.TestCase):
    def test_original_resources_and_preservation(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            expected = {}
            with zipfile.ZipFile(folder / 'fixture.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
                for size in [32, 64, 184]:
                    name = f'graphics/avatar_{size}blank.tga'
                    data = f'original avatar fixture {size}'.encode()
                    archive.writestr(name, data)
                    expected[name] = hashlib.sha256(data).hexdigest()
                archive.writestr('resource/unrelated.txt', b'unneeded resource')
            (folder / 'expected.json').write_text(json.dumps(expected))
            (folder / 'Stubs.swift').write_text('''
import Foundation
func wine_process_is_running() -> Int32 { 0 }
func wineserver_is_running() -> Int32 { 0 }
func madeira_seed_prefix_if_needed(_ path: String) {}
''')
            (folder / 'Probe.swift').write_text(r'''
import Foundation
@main struct Probe {
 static func main() async throws {
  typealias S = SteamRuntimeFiles
  let fm = FileManager.default
  let base = URL(fileURLWithPath: CommandLine.arguments[1])
  let drive = base.appendingPathComponent("drive_c")
  let expected = try JSONDecoder().decode([String:String].self, from: Data(contentsOf: base.appendingPathComponent("expected.json")))
  let archive = try Data(contentsOf: base.appendingPathComponent("fixture.zip"))
  assert(try! S.missingAvatarResources(drive: drive, expected: expected).count == 3)
  try S.restoreAvatarResources(archive, drive: drive, expected: expected)
  assert(try! S.missingAvatarResources(drive: drive, expected: expected).isEmpty)
  let steam = drive.appendingPathComponent(S.relativeRoot)
  assert(!fm.fileExists(atPath: steam.appendingPathComponent("resource/unrelated.txt").path))
  // No network/unpacking is needed on a repeated launch.
  try S.restoreAvatarResources(Data(), drive: drive, expected: expected)
  let existing = steam.appendingPathComponent("graphics/avatar_32blank.tga")
  let newer = Data("newer genuine Steam resource".utf8)
  try newer.write(to: existing)
  try S.restoreAvatarResources(Data(), drive: drive, expected: expected)
  assert((try! Data(contentsOf: existing)) == newer)
  let missing = steam.appendingPathComponent("graphics/avatar_64blank.tga")
  try fm.removeItem(at: missing)
  do { try S.restoreAvatarResources(Data("corrupt archive".utf8), drive: drive, expected: expected); fatalError("accepted corrupt archive") } catch {}
  assert(!fm.fileExists(atPath: missing.path))
  var wrong = expected; wrong["graphics/avatar_64blank.tga"] = String(repeating:"0",count:64)
  do { try S.restoreAvatarResources(archive, drive: drive, expected: wrong); fatalError("accepted wrong bytes") } catch {}
  assert(!fm.fileExists(atPath: missing.path))
  try S.restoreAvatarResources(archive, drive: drive, expected: expected)
  assert((try! Data(contentsOf: existing)) == newer)
  let graphics = steam.appendingPathComponent("graphics")
  try fm.moveItem(at: graphics, to: base.appendingPathComponent("external"))
  try fm.createSymbolicLink(at: graphics, withDestinationURL: base.appendingPathComponent("external"))
  do { _ = try S.missingAvatarResources(drive: drive, expected: expected); fatalError("accepted symlink") } catch {}
  let entries = try fm.contentsOfDirectory(atPath: steam.path)
  assert(!entries.contains { $0.hasPrefix(".winevision-avatar-stage-") })
  print("PASS: actual Steam ZIP extraction, missing avatar repair, repeat launch, newer file preservation, corruption rejection, symlink confinement and staging cleanup")
 }
}
''')
            result = subprocess.run(['swiftc', str(folder / 'Stubs.swift'), str(ROOT / 'Sources/Steam/SteamRuntime.swift'), str(folder / 'Probe.swift'), '-lz', '-o', str(folder / 'probe')], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = subprocess.run([str(folder / 'probe'), str(folder)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
