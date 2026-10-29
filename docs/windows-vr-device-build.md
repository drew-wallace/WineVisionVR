# Current local build — October 29, 2026

The retained Release app is **WineVision VR 0.1.0 (15)** at
`dist/current/WineVision VR.app`. It was rebuilt from the current working tree,
including uncommitted and newly added app/native/shader sources. The existing
Wine/FEX/DXMT binaries were reused after checking their source provenance,
native archive hashes and all 264 staged guest-resource hashes.

The saved app passed strict recursive signature verification, the production
bundle checks, 20 packaging tests, 13 core tests and the app contract test.
This build has not been installed or tested on the headset.

`dist/current/build-summary.json` and `source-files.sha256.json` record the build
and source hashes. Build logs, the tracked working-tree patch and the repeatable
build command are under `.build-device/current/`; run
`bash .build-device/current/rebuild.sh` to replace the current app after edits.

Older app copies and superseded runtime/build caches were removed. The active
runtime is `.build-device/runtime-compatibility-v13`, with staged resources in
`.build-device/compatibility-v13-resources`. `Resources/Runtime` and
`Resources/WindowsVR` link to those current resources. Dependency sources,
toolchains, recovered game data and diagnostic evidence are retained.

## Historical M5 device build — October 27, 2026

The paths below describe the earlier build and are retained as historical
validation notes; its saved app was superseded by build 15.

WineVision VR **0.1.0 (3)** was built from the current working tree, signed for
Apple Development, and installed on the paired physical M5 Vision Pro.
The installed bundle identifier is `org.avpplay.visionos-windows-vr`.

## Saved app

- Release app: `dist/winevision-m5-2026-10-27-build3/WineVision VR.app`
- Artifact hashes and verification summary: `dist/winevision-m5-2026-10-27-build3/build-summary.json`
- Native/guest build caches, generated project inputs and deployment logs: `.build-device/`
- Generated Xcode project: `visionos-windows-vr/VisionOSWindowsVR.xcodeproj`

Keep `.build-device/` and the fetched `third-party/` source trees for incremental
builds. The saved app is a complete signed artifact. No prebuilt runtime from
another installation was needed: the pinned LLVM, Wine, FEX, OpenXR,
OpenComposite and DXMT closure was built locally, with a Wine-generated portable
prefix and matching source/binary receipts.

## Verification

- Optimized Release Xcode build succeeds with Xcode 27 and the visionOS 27 SDK.
- Strict recursive signature verification passes on the built and saved app.
- The signed app has both increased-memory-limit and debugger-attachment entitlements.
- The production Wine import validator checks 109 binaries; graphics, OpenVR,
  ARM64EC pairing, cache compiler/launcher and translator receipts pass.
- The installed app is independently listed by CoreDevice as version 0.1.0, build 3.
- Source/prebuilt configurations agree on version metadata, resources and the
  explicit 1888×1792 baseline. Packaging regressions: 17 tests pass.

The first complete source build also needed three build fixes: staging NLS data
for Wine's native resource compiler, matching D3D12 command-queue constructor/type
usage to its existing interfaces, and bringing the strict graphics verifier's
required patch set up to date. A contract regression now checks that preparation
and staging require exactly the same DXMT patches. App version and custom eye-size
keys are explicit Info.plist properties, because arbitrary custom
`INFOPLIST_KEY_*` settings were omitted from the generated app plist.

## Remaining device validation

The visionOS StikDebug helper is installed, paired with an RPPairing record and
connected over LocalDevVPN. Headset diagnostics confirm the developer disk image
is mounted and the 640 MiB JIT arena was successfully prepared and verified.

The user's Slay the Spire 2 attempt in build 1 reached the Windows loader but
exited with `0xc0000135`: DWrite and UIAutomationCore resolved to incompatible
ARM64 service binaries (`0xc000007b`). Build 2 adds freshly built ARM64EC DWrite,
UIAutomationCore, Oleacc, Uxtheme, Msimg32, Schannel and DSound, including the
static dependency closure. Packaging rejects missing or ARM64-only copies of
these services. Startup notices and errors now remain available in
`Documents/launcher-log.txt` with performance tracing disabled.

The build 2 retry confirmed those services loaded, then exposed finite JIT pool
exhaustion: persistent caching reserves 128 MiB per initial code buffer across
the cache launcher, Dock and Steam. The game was refused even a 1 MiB buffer
with 416 MiB of tail allocations and approximately 180 MiB of DLL head use.
A controlled process override disabling persistent caching advanced into Godot
video initialization without that crash. Build 3 applies that workaround only
to Slay the Spire 2 (Steam app 2868840), preserving explicit cache overrides and
all other games' defaults. It also adds ARM64EC DirectComposition and Ktmw32.

The engine still reported a video-driver initialization error in the D3D12
attempt. Its default path requests interfaces/shader capabilities beyond the
current experimental backend. The ANGLE/Direct3D 11 test created a game window but exposed
shader and .NET runtime failures; successful gameplay has not been established.
See `windows-vr-slay-the-spire2.md` for the controlled comparisons. The experimental M5
tensor backend remains off by default.
Cold/warm game FPS, stereo image quality, controller behavior and sustained thermal
measurements remain the acceptance work in `windows-vr-m5.md`.
