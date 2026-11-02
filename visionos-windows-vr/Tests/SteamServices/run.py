#!/usr/bin/env python3
"""Compile production Steam sync and DLC policies; scripted transport, no Steam account/network."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[3]
src = root / 'visionos-windows-vr/Sources/Steam'
files = ['SteamInstalledLibrary.swift', 'SteamOwnedGame.swift', 'SteamKeyValues.swift', 'SteamCloudClientSettings.swift', 'SteamLibraryMaintenance.swift', 'SteamCloud.swift', 'SteamGameServices.swift', 'SteamDLCStatus.swift',
         'SwiftSteam/Library/SteamPICSMetadata.swift', 'SwiftSteam/Library/SteamAppInfo.swift', 'SwiftSteam/Library/SteamLibraryFetcher.swift',
         'SwiftSteam/Proto/SteamProtoMessages.swift', 'SwiftSteam/Core/SteamError.swift',
         'SwiftSteam/Core/SteamProtocol.swift', 'SwiftSteam/Core/SteamMessageCodec.swift',
         'SwiftSteam/Core/SteamCMSession.swift', 'SwiftSteam/Install/AppManifestWriter.swift']
with tempfile.TemporaryDirectory(prefix='wvr-steam-services-') as temp:
    executable = str(Path(temp) / 'probe')
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    *[str(src / f) for f in files], str(Path(__file__).with_name('Support.swift')),
                    str(Path(__file__).with_name('Probe.swift')), str(Path(__file__).with_name('MetadataProbe.swift')),
                    str(Path(__file__).with_name('ResetProbe.swift')), '-o', executable], check=True)
    subprocess.run([executable], check=True)
