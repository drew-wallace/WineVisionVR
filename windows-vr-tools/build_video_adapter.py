#!/usr/bin/env python3
"""Build the source-owned x64 Bigscreen streaming adapter and GPU probe."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--toolchain', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--amf-architecture', choices=('arm64ec','x64'), default='arm64ec')
    args = parser.parse_args()
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=True)
    compiler = args.toolchain.absolute() / 'bin/x86_64-w64-mingw32-clang++'
    common = [str(compiler), '-std=c++20', '-static', '-O2', '-Wall', '-Wextra', '-Werror']
    amf_common = [str(args.toolchain.absolute() / ('bin/arm64ec-w64-mingw32-clang++' if args.amf_architecture == 'arm64ec' else 'bin/x86_64-w64-mingw32-clang++')), *common[1:]]
    source = ROOT / 'windows-vr-video'
    commands = [
        [*amf_common, '-shared', '-Wno-unused-parameter', '-I', str(ROOT / 'windows-vr-native/include'),
         '-I', str(ROOT / 'windows-vr-native/Sources'),
         '-I', str(source / 'third-party/amf'), str(source / 'guest/VideoAMF.cpp'), '-o', str(output / 'amfrt64.dll')],
        [*common, '-shared', '-I', str(source / 'third-party/unity'), str(source / 'guest/BigSoupAdapter.cpp'),
         str(source / 'guest/BigSoupAdapter.def'), '-o', str(output / 'BigSoup.dll')],
        [*common, '-I', str(source / 'third-party/amf'), '-I', str(ROOT / 'windows-vr-native/Sources'), str(ROOT / 'windows-vr-tools/probes/video_decoder_probe.cpp'),
         '-ld3d11', '-o', str(output / 'mapping-probe.exe')],
    ]
    for index, command in enumerate(commands):
        with (output / f'compile-{index}.log').open('w') as log:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
    package = {'schemaVersion': 1,
               'originalSHA256': '6c88f56e09b810e848fcea0cb2c97ded46c08a94d8e2cd29b2146f0fab64ab04',
               'filesSHA256': {name: sha(output / name) for name in ('BigSoup.dll', 'amfrt64.dll')}}
    (output / 'package.json').write_text(json.dumps(package, indent=2) + '\n')
    inputs = [*source.rglob('*.cpp'), *source.rglob('*.h'), *source.rglob('*.hpp'), *source.rglob('*.def'),
              ROOT / 'windows-vr-native/include/WindowsVRVideoDecoder.h',
              ROOT / 'windows-vr-native/Sources/WindowsVRH264AnnexB.hpp',
              ROOT / 'windows-vr-tools/probes/video_decoder_probe.cpp', Path(__file__).resolve()]
    (output / 'build.json').write_text(json.dumps({
        'schemaVersion': 1, 'compilerCommands': commands, 'amfArchitecture': args.amf_architecture,
        'sourceInputsSha256': {str(p.relative_to(ROOT)): sha(p) for p in sorted(inputs)},
        'artifactsSha256': {name: sha(output / name) for name in ('BigSoup.dll', 'amfrt64.dll', 'mapping-probe.exe', 'package.json')},
        'physicalGPUProbe': 'not-run', 'gameplay': 'not-verified',
    }, indent=2) + '\n')
    print(f'Built video adapter and probe in {output}')


if __name__ == '__main__':
    main()
