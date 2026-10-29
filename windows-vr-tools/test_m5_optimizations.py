#!/usr/bin/env python3
"""Compile M5 policies and run host GPU regressions. No Wine/game/device launch."""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build', type=Path, default=ROOT / '.build-m5-optimizations')
args = parser.parse_args()
build = args.build.resolve()
build.mkdir(parents=True, exist_ok=True)
results = {}


def run(name, command):
    with (build / (name + '.log')).open('w') as output:
        result = subprocess.run(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    results[name] = 'pass' if result.returncode == 0 else 'fail'
    print(f'{name}: {results[name]}', flush=True)
    (build / 'results.json').write_text(json.dumps({
        'scope': 'host CPU/Metal checks and visionOS compilation; no headset game FPS result',
        'checks': results}, indent=2) + '\n')
    return result.returncode == 0


sdk = subprocess.check_output(['xcrun', '--sdk', 'xros', '--show-sdk-path'], text=True).strip()
run('core', ['swift', 'test', '--package-path', str(ROOT / 'windows-vr')])
core = sorted((ROOT / 'windows-vr/Sources/WindowsVRCore').glob('*.swift'))
if run('core-xros', ['xcrun', '--sdk', 'xros', 'swiftc', '-emit-module', '-module-name', 'WindowsVRCore',
        '-target', 'arm64-apple-xros27.0', '-sdk', sdk, *map(str, core),
        '-emit-module-path', str(build / 'WindowsVRCore.swiftmodule')]):
    run('app-typecheck', ['xcrun', '--sdk', 'xros', 'swiftc', '-typecheck', '-parse-as-library',
        '-swift-version', '6', '-target', 'arm64-apple-xros27.0', '-sdk', sdk, '-I', str(build),
        '-import-objc-header', str(ROOT / 'visionos-windows-vr/Sources/WindowsVR-Bridging-Header.h'),
        *map(str, sorted((ROOT / 'visionos-windows-vr/Sources').rglob('*.swift')))])
source = ROOT / 'windows-vr-native/Sources'
include = ROOT / 'windows-vr-native/include'
run('native-xros', ['xcrun', '--sdk', 'xros', 'clang++', '-target', 'arm64-apple-xros27.0',
    '-isysroot', sdk, '-std=c++20', '-fobjc-arc', '-fsyntax-only', '-I', str(include),
    *[str(source / name) for name in ['WindowsVRCompositorBridge.mm', 'WindowsVRGuestFoveation.mm',
       'WindowsVRFrameSynthesis.mm', 'WindowsVRNeuralReconstruction.mm', 'WindowsVRFsr3Upscaler.mm',
       'WindowsVRMetalFXUpscaler.mm', 'WindowsVRMetalDiagnostics.mm']]])
tensor = (include / 'WindowsVRM5TensorConvolution.h').read_text().split('@R"metal(', 1)[1].split(')metal"', 1)[0]
(build / 'tensor.metal').write_text(tensor)
run('tensor-xros', ['xcrun', '--sdk', 'xros', 'metal', '-std=metal4.0',
    '-target', 'air64-apple-xros27.0', '-c', str(build / 'tensor.metal'), '-o', str(build / 'tensor.air')])
fsr_root = ROOT / 'windows-vr-native/third-party/fidelityfx/gpu'
for shader in sorted((fsr_root / 'fsr3upscaler/msl').glob('*.metal')):
    run('fsr-' + shader.stem, ['xcrun', '--sdk', 'xros', 'metal', '-std=metal4.0',
        '-target', 'air64-apple-xros27.0', '-I', str(fsr_root), '-c', str(shader),
        '-o', str(build / (shader.stem + '.air'))])
shader_objects = [build / (shader.stem + '.air') for shader in sorted((fsr_root / 'fsr3upscaler/msl').glob('*.metal'))]
if all(path.is_file() for path in shader_objects):
    run('fsr-library', ['xcrun', '--sdk', 'xros', 'metallib', *map(str, shader_objects),
        '-o', str(build / 'fsr.metallib')])
if run('tensor-host-build', ['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-O2', '-fobjc-arc',
        '-I', str(include), str(ROOT / 'windows-vr-native/Tests/M5TensorConvolutionProbe.mm'),
        '-framework', 'Foundation', '-framework', 'Metal', '-o', str(build / 'tensor-probe')]):
    run('tensor-host', [str(build / 'tensor-probe')])
if run('frame-state-build', ['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-O2', '-fobjc-arc',
        '-DWVR_GUEST_FOVEATION_TEST=1', '-Wl,-export_dynamic', '-I', str(include),
        str(source / 'WindowsVRCompositorBridge.mm'), str(source / 'WindowsVRGuestFoveation.mm'),
        str(ROOT / 'windows-vr-native/Tests/FrameStateWaitProbe.mm'),
        '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore',
        '-o', str(build / 'frame-state-probe')]):
    run('frame-state', [str(build / 'frame-state-probe')])
run('packaging', ['python3', '-m', 'unittest', 'discover', '-s', str(ROOT / 'windows-vr-tools/tests')])
run('frame-path', ['python3', str(ROOT / 'windows-vr-tools/test_fps_batch.py'), '--build', str(build / 'frame-path')])
run('foveation', ['bash', str(ROOT / 'windows-vr-tools/test_guest_foveation.sh')])
run('synthesis', ['bash', str(ROOT / 'windows-vr-tools/test_frame_synthesis.sh'), str(build / 'synthesis')])
# Compare the actual configuration trees without requiring XcodeGen or a Python YAML package.
run('build-parity', ['ruby', '-ryaml', '-e', '''
specs=ARGV.map { |p| YAML.load_file(p) }
apps=specs.map { |s| s.fetch('targets').fetch('VisionOSWindowsVR') }
%w[WVRUniformEyeWidth WVRUniformEyeHeight].each { |k|
 values=apps.map { |a| a.fetch('info').fetch('properties').fetch(k) }
 raise "eye dimensions diverge" unless values.uniq.size==1
}
apps.each { |a|
 %w[CFBundleVersion CFBundleShortVersionString].each { |k| raise "missing #{k}" unless a.fetch('info').fetch('properties').key?(k) }
 raise "weights absent" unless a.fetch('sources').any? { |s| s['path']=='Resources/vr_foveal_student_fp16.wvnw' }
 raise "diagnostics enabled by default" unless a.fetch('info').fetch('properties')['WVRDiagnostics']==false
}
specs.each { |s|
 native=s.fetch('targets').fetch('WindowsVRNativeBridge')
 %w[MetalFX.framework CoreML.framework CoreVideo.framework].each { |f|
  raise "missing #{f}" unless native.fetch('dependencies').any? { |d| d['sdk']==f }
 }
 raise "FSR sources absent" unless native.fetch('sources').any? { |s| s['path'].include?('fidelityfx/gpu/fsr3upscaler/msl') }
 raise "shader flags diverge" unless native.fetch('settings').fetch('base')['MTL_LANGUAGE_REVISION']=='Metal40'
}
puts 'PASS: baseline dimensions, weights, native dependencies, FSR sources, shader flags and diagnostic defaults match'
''', str(ROOT / 'visionos-windows-vr/project.yml'), str(ROOT / 'visionos-windows-vr/project.prebuilt.yml')])
raise SystemExit(1 if 'fail' in results.values() else 0)
