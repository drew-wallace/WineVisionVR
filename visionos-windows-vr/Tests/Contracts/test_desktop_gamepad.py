"""Run virtual Apple gamepads through the adapter and Wine's real transport."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
TRANSPORT = ROOT / 'third-party/madeira/app/Madeira/Winios/WiniosGamepad.c'


class DesktopGamepad(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin' and TRANSPORT.exists(),
                         'Requires macOS GameController and the fetched Madeira transport')
    def test_virtual_controller_to_wine(self):
        with tempfile.TemporaryDirectory(prefix='wvr-desktop-gamepad-') as temp:
            temp = Path(temp)
            subprocess.run(['xcrun', 'clang', '-c', str(TRANSPORT), '-o', str(temp / 'transport.o')], check=True)
            subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                            '-parse-as-library', '-import-objc-header',
                            str(TRANSPORT.with_suffix('.h')),
                            str(ROOT / 'visionos-windows-vr/Sources/Desktop/WindowsDesktopGamepad.swift'),
                            str(ROOT / 'visionos-windows-vr/Sources/Desktop/SteamControllerReport.swift'),
                            str(ROOT / 'visionos-windows-vr/Tests/DesktopGamepadTests.swift'),
                            str(temp / 'transport.o'), '-o', str(temp / 'probe')], check=True)
            subprocess.run([str(temp / 'probe')], check=True, timeout=20)
