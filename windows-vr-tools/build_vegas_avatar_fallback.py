#!/usr/bin/env python3
"""Diagnostic-only avatar proxy, retired because it changes the game build hash.

Build an avatar-only Steam API proxy from a verified user-owned SDK DLL.

The Valve DLL is inspected locally and is never copied into app resources.
All other named exports and ordinals forward to that unchanged original.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = 'b8246e1a629b945fe526b24c3e4f002c4f6eb86aa1b5ed9744399f22a0d2ca9f'
API = 'SteamAPI_ISteamFriends_GetLargeFriendAvatar'
SOURCE = ROOT / 'windows-vr-native/Compatibility/VegasInfinite/SteamAvatarFallback.c'
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--steam-api', type=Path, required=True)
p.add_argument('--toolchain', type=Path, required=True)
p.add_argument('--wine-services', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--resources', type=Path, required=True)
a = p.parse_args()

def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()

assert sha(a.steam_api) == ORIGINAL, 'Unsupported Steam API version; original preserved'
readobj = a.toolchain / 'bin/llvm-readobj'

def exports(path):
    text = subprocess.check_output([str(readobj), '--coff-exports', str(path)], text=True)
    return re.findall(r'Export \{\s+Ordinal: (\d+)\s+Name: ([^\n]+)', text)

original_exports = exports(a.steam_api)
assert len(original_exports) == 859 and sum(name == API for _, name in original_exports) == 1
a.output.mkdir(parents=True, exist_ok=False)
definition = a.output / 'exports.def'
definition.write_text('LIBRARY steam_api64\nEXPORTS\n' + ''.join(
    f'  {name}' + ('' if name == API else f'=wvr_steam_api64_original.{name}') + f' @{ordinal}\n'
    for ordinal, name in original_exports))
proxy = a.output / 'steam_api64.dll'
subprocess.run([str(a.toolchain / 'bin/x86_64-w64-mingw32-clang'), '-shared', '-O2',
                '-Wall', '-Wextra', '-Werror', str(SOURCE), str(definition), '-o', str(proxy)], check=True)
assert exports(proxy) == original_exports, 'Proxy export/ordinal mismatch'
files = {'steam_api64.dll': proxy}
for name in ['vcruntime140_1.dll', 'sensapi.dll']:
    file = a.wine_services / name
    header = subprocess.check_output([str(readobj), '--file-headers', str(file)], text=True)
    assert 'IMAGE_FILE_MACHINE_ARM64EC' in header, name
    files[name] = file
a.resources.mkdir(parents=True, exist_ok=True)
for name, file in files.items(): shutil.copy2(file, a.resources / name)
package = {'schemaVersion': 1, 'originalSHA256': ORIGINAL,
           'filesSHA256': {name: sha(file) for name, file in files.items()}}
(a.resources / 'package.json').write_text(json.dumps(package, indent=2) + '\n')
(a.output / 'build.json').write_text(json.dumps({
    'schemaVersion': 1, 'originalSHA256': ORIGINAL, 'exportsVerified': len(original_exports),
    'interceptedAPI': API, 'pendingAvatarTimeoutMilliseconds': 5000,
    'sourceSHA256': sha(SOURCE), 'package': package,
    'originalValveDLLBundled': False,
    'compiler': subprocess.check_output([str(a.toolchain / 'bin/x86_64-w64-mingw32-clang'), '--version'], text=True).splitlines()[0],
}, indent=2) + '\n')
print('Built avatar proxy: 859 matching exports/ordinals; original Valve DLL remains user-owned.')
