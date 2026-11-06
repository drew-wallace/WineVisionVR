#!/usr/bin/env python3
"""Exercise production desktop pointer sequencing with controlled guest frames."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="wvr-desktop-pointer-") as temp:
    executable = Path(temp) / "probe"
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
        str(ROOT / "visionos-windows-vr/Sources/Desktop/WindowsDesktopPointerInput.swift"),
        str(ROOT / "visionos-windows-vr/Tests/DesktopPointerInputTests.swift"),
        "-o", str(executable)
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=15)
