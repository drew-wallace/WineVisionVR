"""Check branch restrictions from real Steam launch metadata casing."""
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
class PublicLaunchTests(unittest.TestCase):
 def test_branch_and_platform(self):
  with tempfile.TemporaryDirectory() as temp:
   p = Path(temp)
   (p/'Probe.swift').write_text(r'''
import Foundation
enum VDFParser { static func parseTextVDF(from data:Data)->[String:Any] { [:] } }
@main struct Probe {
 static func main() {
  let entries:[String:Any] = [
   "0":["executable":"Bootstrap.exe","config":["oslist":"windows","osarch":"64"]],
   "8":["executable":"Bootstrap.exe","arguments":"Desktop","config":["oslist":"windows"]],
   "9":["executable":"Game.exe","config":["oslist":"windows","BetaKey":"deck"]],
   "10":["executable":"Game.exe","config":["oslist":"windows","betakey":"pentesting"]],
   "11":["executable":"Game.exe","config":["oslist":"linux"]],
   "12":["executable":"Game.exe","config":["oslist":"macos,windows","BetaKey":"public"]]]
  let options = SteamLaunchOption.parse(entries)
  assert(options.first { $0.index==9 }?.betaKey == "deck")
  assert(options.filter(\.supportsPublicWindows).compactMap(\.index) == [0,8,12])
  let decoded = try! JSONDecoder().decode([SteamLaunchOption].self, from: JSONEncoder().encode(options))
  assert(decoded.filter(\.supportsPublicWindows).compactMap(\.index) == [0,8,12])
  print("PASS: original option indices, BetaKey/betakey casing, private branch exclusion and public Windows platform selection")
 }
}
''')
   result = subprocess.run(['swiftc',str(ROOT/'Sources/Steam/SwiftSteam/Library/SteamAppInfo.swift'),str(p/'Probe.swift'),'-o',str(p/'probe')],capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stderr)
   result = subprocess.run([str(p/'probe')],capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stdout+result.stderr)
if __name__=='__main__':unittest.main()
