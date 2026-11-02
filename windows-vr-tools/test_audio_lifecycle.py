#!/usr/bin/env python3
"""Execute the audio lifecycle policy; optionally check observation on visionOS."""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator', help='Booted visionOS 27 simulator UUID')
args = parser.parse_args()
sources = ROOT / 'visionos-windows-vr/Sources'
tests = ROOT / 'visionos-windows-vr/Tests'
with tempfile.TemporaryDirectory(prefix='wvr-audio-lifecycle-') as temp:
    output = Path(temp) / 'probe'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-warnings-as-errors',
                    '-parse-as-library', str(sources / 'WindowsVRAudioRecoveryCoordinator.swift'),
                    str(tests / 'AudioRecoveryCoordinatorTests.swift'), '-o', str(output)], check=True)
    subprocess.run([str(output)], check=True, timeout=15)
    if args.simulator:
        sdk = subprocess.check_output(['xcrun', '--sdk', 'xrsimulator', '--show-sdk-path'], text=True).strip()
        subprocess.run(['xcrun', '--sdk', 'xrsimulator', 'swiftc', '-sdk', sdk,
                        '-target', 'arm64-apple-xros27.0-simulator', '-swift-version', '6',
                        '-warnings-as-errors', '-parse-as-library',
                        str(sources / 'WindowsVRAudioRecoveryCoordinator.swift'),
                        str(sources / 'WindowsVRAudioDiagnostics.swift'),
                        str(sources / 'LaunchLog.swift'), str(tests / 'SimulatorAudioLifecycleProbe.swift'),
                        '-o', str(output)], check=True)
        subprocess.run(['xcrun', 'simctl', 'spawn', args.simulator, str(output)], check=True, timeout=30)
