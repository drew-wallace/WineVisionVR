#!/usr/bin/env python3
"""Stage or verify the pinned, app-owned Slay the Spire 2 ANGLE renderer."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VERSION = "134.0.6998.165"
URL = f"https://storage.googleapis.com/chrome-for-testing-public/{VERSION}/win64/chrome-win64.zip"
FILES = {
    "libEGL.dll": "9c1cc55f2023e724e863a040aaea718ebaf471157c77010aec0b8c49785ec710",
    "libGLESv2.dll": "7e98b68c93f8b12f4c38084abad532f3396367e9dddc13fa876e25ff17b8410c",
    "ABOUT": "795c085a93943043da9dedc50110bc83fe6ed477b9104fa94fc6d4a6aff06dc3",
    "THIRD-PARTY-NOTICES.html": "727c497470298f863906b2c4a0c61f6e6a948cf8bdb7d1cab08b8b690ece3827",
}
MANIFEST = {"schemaVersion": 1, "version": VERSION, "source": URL, "filesSha256": FILES}


def check(name, data):
    if hashlib.sha256(data).hexdigest() != FILES[name]:
        raise ValueError(f"Pinned ANGLE resource differs: {name}")
    if name.endswith('.dll'):
        if len(data) < 64 or data[:2] != b'MZ':
            raise ValueError(f"Not a PE DLL: {name}")
        offset = struct.unpack_from('<I', data, 60)[0]
        if offset < 64 or offset + 6 > len(data) or data[offset:offset+6] != b'PE\0\0\x64\x86':
            raise ValueError(f"Not an x64 PE DLL: {name}")


def verify(output):
    if output.is_symlink() or not output.is_dir():
        raise ValueError(f"Missing ANGLE resource folder: {output}; stage with --archive CHROME_WIN64_ZIP")
    manifest = output / 'manifest.json'
    if manifest.is_symlink() or json.loads(manifest.read_text()) != MANIFEST:
        raise ValueError('ANGLE resource manifest differs from the pinned package')
    for name in FILES:
        path = output / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Missing/non-regular ANGLE resource: {name}")
        check(name, path.read_bytes())


def extract_credits(pak):
    # Chromium DataPack v5, resource 44271: the complete upstream license
    # credits from this exact Chrome build. Node's built-in Brotli decoder
    # avoids introducing a Python package dependency for source preparation.
    version, encoding, count, aliases = struct.unpack_from('<IBxxxHH', pak)
    if version != 5:
        raise ValueError('Unexpected Chromium resource pack version')
    for index in range(count):
        resource, start = struct.unpack_from('<HI', pak, 12 + index * 6)
        _, end = struct.unpack_from('<HI', pak, 12 + (index + 1) * 6)
        if resource == 44271:
            data = pak[start:end]
            if not data.startswith(b'\x1e\x9b') or not shutil.which('node'):
                raise ValueError('Staging upstream notices requires Node.js with Brotli support')
            script = ("const fs=require('node:fs'), z=require('node:zlib');"
                      "process.stdout.write(z.brotliDecompressSync(fs.readFileSync(0))); ")
            return subprocess.run(['node', '-e', script], input=data[8:],
                                  stdout=subprocess.PIPE, check=True, timeout=30).stdout
    raise ValueError('Missing pinned upstream license credits')


def stage(archive, output):
    with zipfile.ZipFile(archive) as source:
        inputs = {name: source.read('chrome-win64/' + name)
                  for name in FILES if name != 'THIRD-PARTY-NOTICES.html'}
        inputs['THIRD-PARTY-NOTICES.html'] = extract_credits(source.read('chrome-win64/resources.pak'))
    for name, data in inputs.items():
        check(name, data)
    if output.exists() or output.is_symlink():
        verify(output)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.angle-stage-', dir=output.parent) as temp:
        staging = Path(temp) / 'ANGLECompatibility'
        staging.mkdir()
        for name, data in inputs.items():
            (staging / name).write_bytes(data)
        (staging / 'manifest.json').write_text(json.dumps(MANIFEST, indent=2, sort_keys=True) + '\n')
        verify(staging)
        staging.rename(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Official Chrome for Testing win64 ZIP; see pinned source URL in this script')
    parser.add_argument('--output', type=Path, default=ROOT / 'visionos-windows-vr/Resources/ANGLECompatibility')
    parser.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    if args.verify:
        verify(args.output)
    elif args.archive:
        stage(args.archive, args.output)
    else:
        parser.error('Provide --archive ZIP to stage, or --verify to validate existing resources')
    print('Verified pinned ANGLE x64 DLLs, provenance and upstream third-party notices.')


if __name__ == '__main__':
    main()
