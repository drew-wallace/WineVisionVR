#!/usr/bin/env python3
"""Exercise the production Bigscreen collector with controlled Unity/OS APIs."""
from pathlib import Path
import subprocess
import tempfile


root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="wvr-bigscreen-memory-") as temporary:
    binary = Path(temporary) / "memory-pressure"
    subprocess.run([
        "xcrun", "clang++", "-std=c++20", "-O1", "-g",
        "-Wall", "-Wextra", "-Werror", "-fsanitize=address,undefined",
        "-I", str(root / "windows-vr-video/tests/windows-mock"),
        "-I", str(root / "windows-vr-video/guest"),
        str(root / "windows-vr-video/tests/memory_pressure.cpp"),
        "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True)
