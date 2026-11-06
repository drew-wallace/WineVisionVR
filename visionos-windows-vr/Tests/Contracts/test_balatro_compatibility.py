"""Exercise the production registry repair and game-scoped launch defaults."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class BalatroCompatibilityTests(unittest.TestCase):
    def test_prefix_identity_and_environment(self):
        stubs = r'''
import Foundation
struct DockGame { let id: Int; let library: String; let installDir: String }
enum DockError: Error { case message(String) }
enum MadeiraDock { static func validate(_ game: DockGame, drive: URL) throws {} }
enum WindowsVRAngleTrial {
    struct Asset { let name: String; let sha256: String }
    static let assets: [Asset] = []
}
'''
        harness = r'''
import Foundation
@main struct Probe {
    static func main() throws {
        typealias B = BalatroCompatibility
        let original = "WINE REGISTRY Version 2\n\n[System\\\\Select]\n\"Current\"=dword:00000002\n\n[System\\\\ControlSet002\\\\Control\\\\ComputerName\\\\ComputerName]\n\"ComputerName\"=\"WINE-PC\"\n\n[Other]\n\"Keep\"=\"value\"\n"
        let result = try B.computerNameRegistry(original)
        precondition(result.hasPrefix(original))
        precondition(result.contains("[System\\\\ControlSet002\\\\Control\\\\ComputerName\\\\ActiveComputerName]\n\"ComputerName\"=\"WINE-PC\""))
        let repeated = try B.computerNameRegistry(result)
        precondition(repeated == result)
        do { _ = try B.computerNameRegistry("invalid"); fatalError("accepted malformed registry") } catch {}
        do { _ = try B.computerNameRegistry("WINE REGISTRY Version 2\n"); fatalError("invented identity") } catch {}
        precondition(B.environment(appID: 1, base: [:]).isEmpty)
        precondition(B.environment(appID: B.appID, base: [:])["LOVE_GRAPHICS_USE_OPENGLES"] == "1")
        precondition(B.environment(appID: B.appID, base: ["SDL_OPENGL_ES_DRIVER": "0"])["SDL_OPENGL_ES_DRIVER"] == "0")
        try B.prepare(game: DockGame(id: 1, library: "../bad", installDir: "bad"), drive: URL(fileURLWithPath: "/missing"))
    }
}
'''
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            (folder / "Stubs.swift").write_text(stubs)
            (folder / "Probe.swift").write_text(harness)
            subprocess.run([
                "swiftc", str(folder / "Stubs.swift"),
                str(ROOT / "Sources/Steam/BalatroCompatibility.swift"),
                str(folder / "Probe.swift"), "-o", str(folder / "probe")
            ], check=True, capture_output=True)
            subprocess.run([str(folder / "probe")], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
