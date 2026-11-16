#!/usr/bin/env python3
"""Build only crypt32's native root-store repair over retained runtime archives."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--runtime-source', type=Path, required=True)
p.add_argument('--baseline-libraries', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
runtime = a.runtime_source.resolve()
baseline = a.baseline_libraries.resolve()
output = a.output.resolve()
output.mkdir(parents=True, exist_ok=False)
relative = Path('build/crypto-unix/crypt32_unixlib_ios.c')
source = output / 'source' / relative
source.parent.mkdir(parents=True)
shutil.copy2(runtime / relative, source)
patch = ROOT / 'windows-runtime-plugin/patches/0029-wine-reusable-root-certificates.patch'
subprocess.run(['patch', '--batch', '--forward', '-p1', '-i', str(patch)], cwd=output / 'source', check=True)
subprocess.run(['python3', str(ROOT / 'windows-vr-tools/test_root_certificate_enumeration.py'),
                '--source', str(source), '--wine-include', str(runtime / 'wine/include')], check=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'xros', '--show-sdk-path'], text=True).strip()
wine = runtime / 'wine'
native = runtime / 'build/ntdll-unix'
crypto = runtime / 'build/crypto-unix'
gnutls_include = runtime / 'toolchains/gnutls-ios/include'
gnutls_tar = runtime / 'build/gnutls-ios/src/gnutls-3.8.9.tar.xz'
if not (gnutls_include / 'gnutls/pkcs12.h').exists():
    # Recover the public headers from the retained archive for the linked
    # GnuTLS version. These are configure's version/iovec substitutions only.
    gnutls_include = output / 'gnutls-include'
    headers = gnutls_include / 'gnutls'
    headers.mkdir(parents=True)
    prefix = 'gnutls-3.8.9/lib/includes/gnutls/'
    with tarfile.open(gnutls_tar) as tar:
        for member in tar.getmembers():
            name = member.name.removeprefix(prefix)
            if not member.name.startswith(prefix) or '/' in name or not member.isfile(): continue
            if not name.endswith(('.h', '.h.in')): continue
            data = tar.extractfile(member).read()
            if name == 'gnutls.h.in':
                text = data.decode()
                for key, value in {'VERSION': '3.8.9', 'MAJOR_VERSION': '3', 'MINOR_VERSION': '8',
                                   'PATCH_VERSION': '9', 'NUMBER_VERSION': '0x030809',
                                   'DEFINE_IOVEC_T': '#include <sys/uio.h>\ntypedef struct iovec giovec_t;'}.items():
                    text = text.replace('@' + key + '@', value)
                data, name = text.encode(), 'gnutls.h'
            (headers / name).write_bytes(data)
obj = output / 'crypt32_unixlib.o'
command = ['xcrun', '--sdk', 'xros', 'clang', '-arch', 'arm64', '-isysroot', sdk,
           '-target', 'arm64-apple-xros27.0', '-O2', '-fPIC', '-fvisibility=hidden',
           '-fno-stack-protector', '-fno-strict-aliasing', '-Wno-implicit-function-declaration',
           '-Wno-int-conversion', '-include', str(wine / 'build-macos/include/config.h'),
           '-include', str(native / 'shims/wine_ios_exit.h'),
           '-I' + str(native / 'shims'), '-I' + str(runtime / 'build/madsync'), '-DHAVE_LINUX_NTSYNC_H=1',
           '-I' + str(wine / 'build-macos/include'), '-I' + str(wine / 'include'),
           '-D__WINESRC__', '-D_NTSYSTEM_', '-D_ACRTIMP=', '-DWINBASEAPI=', '-DWINE_UNIX_LIB', '-DWINE_IOS=1',
           '-D__wine_unix_call_funcs=crypt32_unix_call_funcs',
           '-D__wine_unix_call_wow64_funcs=crypt32_unix_call_wow64_funcs',
           '-I' + str(wine / 'dlls/crypt32'), '-I' + str(gnutls_include),
           '-include', str(crypto / 'ios_gnutls_shim.h'), '-c', str(source), '-o', str(obj)]
with (output / 'compile.log').open('w') as log:
    subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
libraries = output / 'libraries'
libraries.mkdir()
for path in baseline.iterdir():
    if path.name != 'libntdll_unix.a': (libraries / path.name).symlink_to(path.resolve())
archive = libraries / 'libntdll_unix.a'
original = baseline / archive.name
shutil.copy2(original, archive)
subprocess.run(['xcrun', 'ar', 'r', str(archive), str(obj)], check=True)
subprocess.run(['xcrun', 'ranlib', str(archive)], check=True)
def sha(path):
    with path.open('rb') as f: return hashlib.file_digest(f, 'sha256').hexdigest()
def members(path):
    names = [name for name in subprocess.check_output(['xcrun', 'ar', 't', str(path)], text=True).splitlines()
             if not name.startswith('__.SYMDEF')]
    assert len(names) == len(set(names)), 'Duplicate archive members require explicit review'
    return {name: hashlib.sha256(subprocess.check_output(['xcrun', 'ar', 'p', str(path), name])).hexdigest() for name in names}
before, after = members(original), members(archive)
assert before.keys() == after.keys()
changed = [name for name in before if before[name] != after[name]]
assert changed == ['crypt32_unixlib.o'], changed
(output / 'build.json').write_text(json.dumps({'schemaVersion': 1, 'baselineArchiveSha256': sha(original),
    'nativeArchiveSha256': sha(archive), 'sourceSha256': sha(source), 'patchSha256': sha(patch),
    'sourceInputsSha256': {str(p.relative_to(ROOT)): sha(p) for p in [Path(__file__).resolve(), patch,
        ROOT / 'windows-vr-tools/test_root_certificate_enumeration.py']},
    'changedArchiveMembers': changed, 'unchangedArchiveMembers': len(before) - 1,
    'gnutlsSourceArchiveSha256': sha(gnutls_tar),
    'compileCommand': command, 'tests': 'pass; actual enumerator under ASan/UBSan'}, indent=2) + '\n')
print(f'Built {archive}; only crypt32_unixlib.o changed.')
