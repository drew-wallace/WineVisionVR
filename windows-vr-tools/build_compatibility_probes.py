#!/usr/bin/env python3
"""Build isolated x64 Windows mapping/.NET probes. Does not launch Wine or games."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "windows-vr-native/Tests/Compatibility"


def build(output, compiler, dotnet, angle_include=None):
    output.mkdir(parents=True, exist_ok=True)
    mapping = output / "mapping"
    mapping.mkdir(exist_ok=True)
    subprocess.run([str(compiler), "-O2", "-Wall", "-Wextra", "-Werror",
                    str(SOURCE / "SharedExecutableMappingProbe.c"), "-o", str(mapping / "mapping-probe.exe")], check=True)
    destinations = [(mapping, "mapping-probe.exe", "winevision.probe.mapping")]
    if angle_include:
        angle = output / "angle"
        angle.mkdir(exist_ok=True)
        subprocess.run([str(compiler), "-O2", "-Wall", "-Wextra", "-Werror", "-I", str(angle_include),
                        str(SOURCE / "AngleDrawingProbe.c"), "-o", str(angle / "angle-probe.exe"), "-luser32"], check=True)
        destinations.append((angle, "angle-probe.exe", "winevision.probe.angle"))
    if dotnet:
        managed = output / "managed"
        subprocess.run([str(dotnet), "publish", str(SOURCE / "ManagedRuntimeProbe/ManagedRuntimeProbe.csproj"),
                        "-c", "Release", "-r", "win-x64", "--self-contained", "true",
                        "-p:NuGetAudit=false", "-p:BaseIntermediateOutputPath=" + str(output / "managed-obj") + os.sep,
                        "-p:BaseOutputPath=" + str(output / "managed-bin") + os.sep,
                        "-o", str(managed)], check=True)
        destinations.append((managed, "ManagedRuntimeProbe.exe", "winevision.probe.managed"))
    for directory, executable, identity in destinations:
        binary = (directory / executable).read_bytes()
        assert binary[:2] == b"MZ"
        pe = struct.unpack_from("<I", binary, 0x3c)[0]
        assert binary[pe:pe+4] == b"PE\0\0" and struct.unpack_from("<H", binary, pe+4)[0] == 0x8664
        (directory / "manifest.json").write_text(json.dumps({
            "id": identity, "title": identity, "executableRelativePath": executable,
            "backend": "windowsWineFEX", "graphics": "direct3D11", "presentation": "desktop",
            "launchArguments": [], "environment": {"FEX_ENABLECODECACHINGWIP": "0"}, "schemaVersion": 1
        }, indent=2) + "\n")
    hashes = lambda base: {str(p.relative_to(base)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in sorted(base.rglob("*")) if p.is_file()
                          and "result" not in p.name.lower()}
    (output / "build.json").write_text(json.dumps({
        "schemaVersion": 1, "executed": False,
        "sourceSha256": {str(p.relative_to(SOURCE)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted(SOURCE.rglob("*")) if p.suffix in {".c", ".cs", ".csproj"}
                         and "bin" not in p.parts and "obj" not in p.parts},
        "filesSha256": {directory.name: hashes(directory) for directory, _, _ in destinations},
        "compiler": subprocess.check_output([str(compiler), "--version"], text=True).splitlines()[0],
        "dotnetSDK": subprocess.check_output([str(dotnet), "--version"], text=True).strip() if dotnet else None,
        "runtimeVersion": "9.0.7" if dotnet else None,
        "angleHeadersSha256": {str(p.relative_to(angle_include)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in sorted(angle_include.rglob("*.h"))} if angle_include else None
    }, indent=2) + "\n")
    print(f"Built {len(destinations)} compatibility probes at {output}; not executed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--compiler", type=Path, required=True)
    parser.add_argument("--dotnet", type=Path, help="Optional .NET 9 SDK executable; publishes self-contained runtime 9.0.7")
    parser.add_argument("--angle-include", type=Path, help="Optional pinned official ANGLE headers; builds ANGLE pixel probe")
    args = parser.parse_args()
    # LLVM-MinGW's target wrapper selects its triple from argv[0]. Preserve
    # its symlink name instead of resolving it to clang-target-wrapper.sh.
    build(args.output.resolve(), args.compiler.absolute(), args.dotnet.absolute() if args.dotnet else None,
          args.angle_include.resolve() if args.angle_include else None)
