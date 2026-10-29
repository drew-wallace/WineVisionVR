# Slay the Spire 2 device diagnosis — October 27, 2026

Steam app 2868840 was tested on the user's physical M5 Vision Pro in desktop
mode. **Gameplay has not been reached.** StikDebug pairing and JIT preparation
work; the remaining failures are runtime and graphics compatibility issues.

## Repaired startup failures

- Build 1 exited with `0xc0000135` after DWrite and UIAutomationCore resolved
  to ARM64 service copies (`0xc000007b`) in an ARM64EC/x64 session. Build 2
  packages ARM64EC DWrite, UIAutomationCore, Oleacc, Uxtheme, Msimg32, Schannel
  and DSound. The device retry confirms the game loads those DLLs.
- The next failure exhausted the 640 MiB code pool. Persistent caching starts
  with 128 MiB code buffers in the cache launcher, Dock and Steam, leaving
  insufficient room for the game. The trace shows 416 MiB of tail allocations
  and roughly 180 MiB of DLL head use, followed by refusal of even a 1 MiB
  buffer and FEX's deliberate `0xdead` failure.
- A controlled `FEX_ENABLECODECACHINGWIP=0` run advanced into video setup.
  Build 3 applies that default only to this measured Steam game. Explicit
  manifest and inherited process overrides remain respected. Other games
  retain persistent caching.
- Godot then required DirectComposition before creating its D3D12 device.
  Build 3 adds ARM64EC Dcomp and Ktmw32. The normal renderer still fails video
  initialization. The log records an unsupported `D3D12GetInterface` query.
  The current backend supports SM5.1/DXBC; Godot's D3D12 implementation requires
  SM6/DXIL. Adding a DLL does not add that shader support.

## Controlled ANGLE and .NET experiments

An isolated fallback test added `libEGL.dll`, `libGLESv2.dll` and `override.cfg`
alongside the user's game executable. The override selected
`gl_compatibility` and `opengl3_angle`. The DLLs came from Google's official
Chrome for Testing 134.0.6998.165 Windows x64 archive; local SHA256 provenance
is retained in `.build-device/angle-cft-fallback/provenance.json`. These files
are not included in the WineVision app bundle.

This route loaded ANGLE, entered D3D11, and created a 1912×1046 game client
window. It also logged `Geometry shader cannot be independently converted.`
Rendering correctness was not established.

The bundled .NET 9.0.7 runtime then failed GC initialization while trying to
reserve `0x3f74500000` bytes (about 254 GiB) of virtual address space. This was
a virtual reservation failure, not exhaustion of physical headset RAM.

A process-only `DOTNET_GCRegionRange=200000000` test (hexadecimal: 8 GiB)
successfully reserved `0x200000000` bytes, but then CoreCLR terminated with
`0xc0000602` after a write-barrier patch assertion:
`0xf0f0f0f0f0f0f0f0 == *(UINT64*)m_pRegionToGenTableImmediate`.
A further process-only `DOTNET_EnableWriteXorExecute=0` comparison changed
the failure to an access violation inside CoreCLR. These results do not
justify a permanent GC or W^X setting, bypassing assertions, or claiming
support for the game.

The temporary ANGLE/configuration files are removed after the experiment;
the game's original `sts2.runtimeconfig.json` was read and preserved without
modification. GC and W^X trial variables are absent from app defaults.

## Verification and remaining work

Build 3 compiles and signs for visionOS; strict signatures, 109 packaged PE
dependency checks, graphics/OpenVR/cache receipts, 17 packaging regressions,
and translation-policy override checks pass. It is installed on the headset.

The next compatibility work is a minimal .NET 9 write-barrier/dual-mapping
reproducer under the existing translator, plus a separate ANGLE geometry
shader probe. Preserve allocator ownership, cache invalidation and GPU-event
progress contracts. Do not replace those contracts with advertised feature
levels or suppressed runtime assertions.

Primary references:

- [Godot ANGLE setup](https://docs.godotengine.org/en/4.4/contributing/development/compiling/compiling_for_windows.html#compiling-with-angle-support)
- [Godot D3D12 shader-model requirements](https://github.com/godotengine/godot/blob/4.6/drivers/d3d12/rendering_device_driver_d3d12.cpp)
- [.NET GC reservation configuration](https://learn.microsoft.com/dotnet/core/runtime-config/garbage-collector)
- [.NET 9.0.7 write-barrier code](https://github.com/dotnet/runtime/blob/v9.0.7/src/coreclr/vm/amd64/jitinterfaceamd64.cpp)

## Build 4 implementation checkpoint

The installed game identifies itself as `v0.107.1`, commit `59260271`.
Its exact Godot engine version is still unconfirmed. The earlier shader-model
comparison uses upstream engine source, not an engine version extracted from
this executable.

A new standalone Windows x64 mapping probe reproduced an executable-section
sharing defect on the physical headset, independently of Steam, Godot and .NET:

```text
ordinary SEC_COMMIT shared views: PASS
ordinary SEC_RESERVE shared views: PASS
executable SEC_RESERVE views:
  primary immediate = 0x0000000000000000
  writer immediate  = 0xf0f0f0f0f0f0f0f0
  FAIL copy-visible-before-flush
```

The Wine trace shows the executable view being copied and remapped into the
native JIT pool, while its writable section view retains the original backing.
This provides a direct explanation for the fixture's missing bytes and matches
CoreCLR's copy-then-read write-barrier failure. Passing the managed device probe
is still required to establish that the repair resolves CoreCLR startup.

Source patch `0019-wine-shared-executable-sections.patch` preserves shared
pagefile-backed sections containing guest x64 code. Host execute permission is
unnecessary for bytes decoded by FEX. Wine's logical protections and existing
FEX map/protect/cache-flush notifications remain in place. Native EC allocations,
images, mapped file assets, JIT-pool ranges, copy-on-write views and existing
aliases retain their prior paths. The classifier checks the entire range.

Three standalone fixtures now live in `windows-vr-native/Tests/Compatibility/`:

- Mapping: shared-view byte visibility before cache flushing, section offsets,
  writer remapping, repeated executable-code patches and translation invalidation.
- Managed runtime: .NET 9.0.7 startup, old-to-young object stores, forced GC and
  generated-code execution. Its host reference run passed all 48 iterations
  with default GC and W^X settings.
- ANGLE: explicit hardware D3D11 selection, textured triangles and point sprites,
  alpha blending, resize, repeated presentation and pixel readback. This tests
  ANGLE directly; a matching exported Godot scene remains additional work.

`build_compatibility_probes.py` builds Windows x64 executables and records source,
header and output hashes. `run_compatibility_probe.py` runs one fixture using the
diagnostic app's explicit `--compatibility-probe` argument. Results carry unique
run IDs; an old result cannot pass a new run when startup fails. Probe files now live
under a fresh `Documents/WindowsVR/ProbeRuns/<UUID>/<probe>/` folder for each run. They do not
replace game files or install persistent GC/W^X settings. The optional
`--gc-region-range` runner argument is an explicit managed-process comparison.

The runtime was prepared in a fresh source overlay. Native ntdll was recompiled,
the graphics closure was rebuilt through its receipt-gated pipeline, and
unchanged native component outputs were reused only after checking their
source inputs. Fresh native, guest and staged resource receipts were generated.
The Release build **0.1.0 (4)** compiled, passed strict recursive signatures and
109 PE dependency checks, and was installed on the physical headset. Eighteen
packaging/result regressions and the native-memory exclusion regression passed.

**Post-fix execution remains unverified.** Subsequent CoreDevice launch requests
for both WineVision and the existing StikDebug app timed out, although device
file transfer and installation continued to work. The corrected mapping probe,
managed device stress run and ANGLE pixel probe therefore have no post-fix pass.
The game-specific ANGLE profile has not been made the default; the original
D3D12 graphics incompatibility and playable-game acceptance remain open.

Local evidence and rebuild inputs:

- `.build-device/compatibility-implementation-checkpoint.json`
- `.build-device/compatibility-probes/mapping/device-result.txt` (baseline failure)
- `.build-device/compatibility-mapping-runtime.txt`
- `.build-device/compatibility-managed-host-run.log`
- `.build-device/runtime-compatibility-modern/` (prepared and compiled runtime)
- `.build-device/compatibility-resources/` (matching staged resources)
- `visionos-windows-vr/.local.compatibility.yml` (generated machine-local app spec)
- `.build-device/compatibility-runs/mapping-fixed-1/receipt.json` (launch failure)

Resume with the mapping fixture on build 4, then the managed fixture with default
settings and a separately recorded bounded-reservation comparison if necessary.
Run ANGLE pixel checks before integrating or promoting the game launch profile.


## October 28: managed startup and black-window diagnosis

Builds 4–6 established the following on the physical M5 headset:

- The corrected shared-section fixture passes all four section/offset cases
  and all 16 generated-code executions (values 41–48 across two views).
- Default .NET 9.0.7 still cannot reserve its approximately 256 GiB GC region.
  A process-only hexadecimal `DOTNET_GCRegionRange=200000000` (8 GiB) comparison
  advances startup without changing the game's runtime configuration or W^X.
- Pure IL assembly imports also require Wine's ARM64EC `mscoree.dll`.
  Build 5 builds and requires that dependency. The managed device probe then
  passes all 48 old-to-young reference/collection/generated-code rounds.
- ANGLE selects hardware D3D11 and returns the expected blended pixels for
  textured triangles and point sprites over twelve frames and a resize.
  Uninstrumented EGL teardown has stalled; an instrumented run completed but
  does not establish that teardown is fixed. Symbol initialization/watchdog
  instrumentation has been removed from the fixture, and DLL unload is now
  also required before its PASS result.

The user's subsequent screenshot shows a black window with teal bands. Its
captured runtime log confirms the actual game launched through Steam with
`--rendering-method gl_compatibility --rendering-driver opengl3_angle`.
It did not reach gameplay. .NET reports a fatal access violation while calling
`System.Environment.GetOSVersion()` from culture-aware dictionary hashing in
`Internal.Runtime.InteropServices.ComponentActivator`.

The first native fault is in a **second** ARM64EC ntdll, mapped from
`C:\windows\sysx64\ntdll.dll` after .NET tries an absolute game-directory path.
The bootstrap ntdll already exists under its system32 identity. The fallback
maps another image, whose `current_version` pointer is null. Its faulting
instruction at ntdll RVA `0x76aa4` reads `[x8 + 4]` with `x8 = 0`, matching
`RtlGetVersion`'s first version-field read. This is a loader identity failure;
the black surface is not evidence of successful managed initialization.

Patch `0020-wine-bootstrap-ntdll-fallback.patch` makes only this ARM64EC fallback
reuse the current process's bootstrap ntdll. It verifies the bootstrap DDAG
node and does not merge other DLLs or another pseudo-process's ntdll by name.
The scope regression compiles the production helper and covers missing/wrong
process state and unrelated DLL names. The managed fixture now includes OS
version and culture-aware dictionary checkpoints before its GC stress loop.
Device execution of this extension and the repaired game launch remain required.

The opt-in game trial now supplies its bounded GC range through the selected
manifest, while retaining explicit manifest/process overrides. Verified ANGLE
inputs may come from a UUID-scoped probe directory. This remains a developer
trial, not a default compatibility claim or a public ANGLE distribution.

### Diagnostic transfer incident and recovery

A diagnostic transfer used CoreDevice's `--remove-existing-content` option to
refresh equal-size rebuilt executables that incremental copying had skipped.
The operation cleared more app data than intended; the user had to set up
Steam and download the game again. That option has been removed. Each probe
now uploads to a fresh UUID directory, copies its executable back and verifies
its SHA256 before launch. A regression rejects removal flags and non-unique
transfer paths. No remote directory removal is requested by the runner.

The recovered install record and complete game directory were copied to
`.build-device/recovered-sts2-backup/` before further successful installation.
The game backup contains 223 files totaling 2,918,022,970 bytes, including
`SlayTheSpire2.exe` (894,748,672 bytes) and `SlayTheSpire2.pck`
(1,901,378,340 bytes). SHA256 values are in `game-files.json`. Steam userdata
was also copied successfully. This preserves recovered data; it cannot
establish that every item present before the incident was recovered.

Evidence:

- `.build-device/compatibility-runs/mapping-fixed-awake-1/`
- `.build-device/compatibility-runs/managed-v5-8g-1/`
- `.build-device/compatibility-runs/angle-v5-ready-watchdog-1/`
- `.build-device/black-screen-latest-runtime.txt`
- `.build-device/black-screen-latest-launcher.txt`
- `.build-device/recovered-sts2-backup/game-files.json`
- `.build-device/compatibility-v8-reuse.json`

CoreDevice file access and installation recovered, but the build-7 extended
managed-probe launch timed out. A timeout is not a test pass or a reproduction
of the expected loader fault. Keep that receipt separate from the successful
older managed fixture and obtain fresh post-fix evidence before claiming play.


Build **0.1.0 (8)** compiles with patch 0020 and the safe UUID probe runner.
Its ARM64EC ntdll is rebuilt from the freshly prepared source. Comparison of
16,655 source files identified only the expected PE loader change relative to
build 5; the 19 unchanged native archives were reused with hashes recorded.
The modern graphics closure was rebuilt and all native/guest/staging receipts
were regenerated. Release signing and 110 PE import/forwarder checks pass.
Nineteen tool regressions, both native scope regressions, and the Swift
publication/recovery contract pass. These build checks do not validate the
new loader behavior on the headset.


The build-8 extended managed fixture subsequently **passed on the headset**
(run `0f07f9d6-8e4c-4fc7-a39d-6fb3c6c15704`): OS version `10.0.19045.0`,
culture-aware dictionary lookup, and all 48 GC/generated-code rounds, with an
8 GiB process reservation and default W^X. Evidence is in
`.build-device/compatibility-runs/managed-os-version-fixed-1/`.
Restarting the stale StikDebug session restored app launching. This improves
the runtime evidence but does not yet establish successful game rendering.


## Build 9: persistent library selection and compiler shutdown

The user's next ordinary library launch reproduced the original driver dialog.
Its trace confirms `SlayTheSpire2.exe` was launched without the ANGLE arguments
and reached `D3D12GetInterface`. The successful build-8 trial had only selected
ANGLE for its diagnostic process; it did not configure ordinary Play.

Build 9 adds a per-game **Experimental compatibility renderer** toggle. A
verified diagnostic import copies the two pinned DLLs into the app-owned
`WindowsVR/CompatibilityAssets/ANGLE-914c97c116e0` cache, then enables the
preference. Normal library launches read that preference and prepare ANGLE
from the cache. They apply the bounded .NET reservation when constructing the
actual launch manifest, so changing the toggle after selecting a game works.
Explicit caller GC settings retain precedence. Other games are unchanged.
Original or modified game DLLs remain protected by the ownership journal.

The actual game now identifies the engine as
`MegaDot v4.5.1.m.12.mono.custom_build`. The build-8 ANGLE trial's Godot log
confirms hardware D3D11 on Apple M5, .NET/game assemblies, Steamworks
initialization, save migrations, atlas loading, localization, and model ID
serialization initialization. It does not confirm a menu or gameplay.
The earlier uncertainty about the engine version is resolved to that banner;
its custom engine source revision is still unknown.

An additional build-8 worker fault resolves to d3d11 native RVA `0x5bff0`,
`std::__hash_table<std::string>::find`, during initial device setup. Source
review identifies an invalid cache destruction order: `scheduler_` is declared
before its task-owning caches and would join workers after those caches have
been destroyed. Patch `0049-dxmt-pipeline-worker-lifetime.patch` explicitly
joins workers before releasing cache/blend data. It also sets shutdown state
under the condition-variable mutex, preventing a lost shutdown wakeup. This
is a demonstrated source lifetime defect; attribution of every observed
worker fault to it requires the new device run.

`test_dxmt_scheduler.py` compiles the actual prepared scheduler header with
portable host thread primitives and ASan/UBSan. It checks in-flight work blocks
shutdown until released, idempotent shutdown/destruction, and 500 idle-worker
shutdowns. The test passes. Swift profile tests cover persistent enablement,
ordinary-launch cache lookup, and preservation of conflicting cached files.

The clean, uninstrumented ANGLE fixture passed on build 8, including twelve
pixel readbacks, resize, EGL teardown and both DLL unloads:
`.build-device/compatibility-runs/angle-raw-v8-1/`. This replaces the earlier
instrumented-only teardown evidence, but a repeated build-9 run is still needed.

Build 9 compiles, passes strict signing and 110 packaged PE import/forwarder
checks, and is installed. Fresh source/build/staging receipts include patch
0049 and its complete staging allowlist. Game launch verification follows
installation; the profile is still experimental.


### Final profile adoption and shutdown submission guard (build 10)

The cached ANGLE DLLs have been copied to the headset's app-owned compatibility
cache and copied back with both pinned SHA256 values verified
(`.build-device/compatibility-profile-assets.json`). On startup, build 10
validates the complete cache before adopting an installed profile when no
preference exists. An explicit disabled preference remains disabled. This
permits an ordinary library launch to use the installed files without an
automation flag or a diagnostic run directory.

Patch 0049 also rejects normal/low-priority submissions and promotions after
shutdown begins, under the worker mutex. This prevents a finishing worker from
adding threads while shutdown iterates and joins the worker list. The final
prepared header again passes the in-flight join, repeated shutdown and 500
idle-cycle ASan/UBSan check. The tool suite now has 20 passing cases, including
an equal-size stale-copy test that proves a hash mismatch prevents launching.

The build-9 ANGLE retries timed out at app launch. They did not execute the
fixture and are not regression failures or passes. Installation and file
transfer still work. A fresh ordinary library launch of the final app remains
the next device check. Earlier build-8 managed and raw ANGLE passes remain
separate evidence.


Build **0.1.0 (10)** is built, signed, dependency-checked and installed. A
signed copy and evidence summary are retained at
`dist/winevision-m5-2026-10-28-build10/`. Its ordinary Steam test launch used
only `WVR_AUTOMATED_LAUNCH=1` to select/start the saved game, without renderer,
asset-run or GC overrides. CoreDevice timed out at the app-launch request;
this does not establish that the profile was exercised or that a menu rendered.
The receipt is `.build-device/compatibility-runs/game-v10-normal-1/receipt.json`.
Resume with a fresh app opening on the awake/unlocked headset, check the
Slay the Spire 2 compatibility toggle, then inspect its fresh command line and
Godot log. The game directory and Steam account should not need replacing.

Superseded generated source trees from this session were removed to recover
host disk space. Their provenance/build receipts, signed app snapshots,
logs and the relevant unstripped ntdll were retained. The current
`.build-device/runtime-compatibility-v10-final/` and its staged resources remain
available for rebuilding and diagnosis.


## Build 11: fullscreen black window and memory-query progress

The user's subsequent manual build-10 launches (12:14 and 12:17 local time)
confirm that the persistent profile is exercised: Steam starts the game with
both ANGLE compatibility arguments. The game identifies hardware ANGLE/D3D11
on M5 and reaches managed initialization, Steamworks, atlases, and localization.
No unhandled exception or process termination appears in the captured latest
run. The fullscreen black window remains a failure, not a playable result.

The main game thread is blocked in `libsentry.windows.release.x86_64.dll`
(RVA `0xaa527`) through `NtFsControlFile` / `server_ioctl_file`, waiting on an
asynchronous operation for more than 160 seconds. Its Crashpad helper is
actively querying memory: `get_mapping_committed_range` accounts for about
192,000 of each 200,000 server requests, roughly 25,000 requests/second.
The engine log stops after model-ID serialization-cache initialization.

A focused host fixture reproduces a concrete query-contract defect in the
actual prepared `get_committed_size` implementation. WineVision shares one
host view tree across pseudo-processes, whereas wineserver records reserved
section views per Windows process. Querying a sibling's physical SEC_RESERVE
view can therefore return `STATUS_NOT_MAPPED_VIEW` from wineserver, leave the
computed range zero, and nevertheless return a successful basic-memory query
with `RegionSize == 0`. That violates memory-walk progress. Crashpad's
[Windows memory enumeration](https://chromium.googlesource.com/crashpad/crashpad/+/refs/heads/main/util/win/process_info.cc)
uses these region sizes; the installed helper's exact source revision is
unknown. The request/stack evidence supports this as the next fault to test,
not yet a completed causal device verification.

Patch `0021-wine-shared-view-memory-query.patch` adds a narrowly scoped iOS
fallback for `STATUS_NOT_MAPPED_VIEW`: report the existing local view's actual
vprot ranges, clipped to its bounds and the caller's maximum. It does not set
commit bits, change protections or substitute for successful server replies.
Other server errors retain failure behavior, and an unexpected zero size in
a basic query fails with `STATUS_INVALID_ADDRESS` instead of returning invalid
success metadata.

`test_shared_view_query.py` compiles the prepared production function with
controlled server/view fixtures and ASan/UBSan. The build-10 baseline fails the
foreign-view progress assertion; the corrected source passes foreign committed
and reserved boundaries, range caps, server-authoritative owned commits,
non-reserved views, and unrelated server errors. Evidence:

- `.build-device/shared-view-query-baseline.log`
- `.build-device/shared-view-query-final.log`
- `.build-device/black-fullscreen-runtime.txt`
- `.build-device/black-fullscreen-godot.log`

The Windows mapping fixture now also creates a reserved section in a parent,
queries that address in its child, and walks the child's address space with
explicit progress and termination bounds. It then repeats the original shared
mapping/execution checks. Its initial device launch timed out; that is separate
from the successful host reproduction. A fresh device pass remains required.

The changed `virtual.o` was recompiled for arm64 visionOS with the runtime's
native build flags and matching generated Wine headers. All 36 other archive
object members are byte-identical; only that object and the regenerated archive
symbol index changed. Native object hashes are retained in
`.build-device/compatibility-v11-native-object-rebuild.json`. The graphics
closure and native/guest/staging receipts were rebuilt from fresh source
profiles before app assembly.


Build **0.1.0 (11)** compiles, passes strict signing and the 110 PE dependency
checks, and is installed. The host tool suite has 20 passes; the focused memory
query fixture passes with sanitizers. Device testing of this candidate remains
pending the headset's availability; no new device pass or playable result is
claimed. The signed app and evidence summary are in
`dist/winevision-m5-2026-10-28-build11/`.


The user made the headset available and the build-11 mapping/memory-query
fixture **passed on device** (run `368587e0-49fe-449b-8000-7d801c2a0dcd`).
The child query returns a valid 64 KiB reserved region for the parent's physical
view. Its complete memory walk terminates after 213 regions, and all 16
patched-code executions plus the four original shared-section cases pass.
The native log confirms the new `STATUS_NOT_MAPPED_VIEW` fallback was exercised.
Evidence is in `.build-device/compatibility-runs/foreign-query-v11-1/`.
An ordinary-profile Steam game retry was then accepted by the launch service;
game startup/menu verification follows independently.


## Build 12: explicit texture-compression metadata and BC7 eligibility

The build-11 ordinary-profile game retry passed the previous startup wait.
The engine log advances through profile saves, controller-atlas initialization,
fullscreen display configuration, VSync and Steam statistics. Sentry's native
SDK reports an initialization failure and returns control to the game.
The memory-query fallback is exercised by this actual game run. The crash
reporter has further compatibility issues; successful reporting is not claimed.

The next fatal condition is a direct Metal validation assertion:
`MTLPixelFormatBC7_RGBAUnorm does not support lossy compression`.
The user confirms the game remains black. The trace also still contains the
earlier D3D11 worker fault, so patch 0049 alone has not established a complete
resolution for that separate fault.

Source review finds `WMTTextureInfo::compression` was introduced in patch 0036,
but ordinary C++ texture descriptors could leave it uninitialized. The native
boundary previously treated any nonzero value as a lossy-compression request
and did not validate pixel format or texture topology.

Patch `0050-dxmt-safe-texture-compression.patch` value-initializes descriptor
storage across the guest texture creation paths. The native policy requires
an exact explicit request, private 2D single-sample/single-slice storage, render
target usage without shader-write or format-view access, and the existing five
opt-in ordinary color formats. It preserves storage options and rejects BC,
ASTC/EAC, depth, integer, sRGB and other unsupported formats. Apple's
[Metal feature tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
identify format groups incompatible with this compression feature.

`test_lossy_texture_eligibility.py` compiles the actual native policy against
Metal/Foundation and checks the allowed formats, compressed/depth/integer
exclusions, explicit request values, usage, storage and topology boundaries
with ASan/UBSan. It also rejects uninitialized C++ descriptor declarations.
The test passes. The standalone ANGLE fixture now uploads a valid opaque-black
BC7 block, draws it, and requires matching RGBA pixel readback before teardown.
The new device fixture and game retry remain to be run after installation.

Evidence is under `.build-device/compatibility-runs/game-v11-normal-1/`,
`.build-device/compatibility-v12-lossy-test.log`, and the versioned source patch.

Build **0.1.0 (12)** is signed and installed. The updated ANGLE fixture
**passed on the physical M5 headset**, run
`1b4ab4e9-3641-44d3-824d-8ec69685f452`: twelve textured/blended triangle and
point frames survive resizing, the BC7 block reads back `(0,0,0,255)` with
no GL error, and full context/surface/EGL/DLL teardown completes before PASS.
No warmup exception or Metal assertion appears in this probe run. Evidence:
`.build-device/compatibility-runs/angle-bc7-v12-1/`.

The user's intervening retry showed the game cursor over black and then quit.
Its copied launcher log identifies the build-11 bundle UUID, and its runtime
log reproduces the BC7 compression assertion; it is not evidence against the
newly installed build-12 fix. An ordinary saved-profile game launch on build 12
was accepted separately; game-menu acceptance remains to be checked.

The first build-12 ordinary game run uses the installed build-12 bundle and
the saved ANGLE profile. It logs main-menu arrival in **19,438 ms**, finishes
preloading 778 common assets, and subsequently records character-lobby
initialization plus menu button interactions. The captured runtime log extends
past the old crash point without a BC7 assertion or unhandled exception.
This establishes progress beyond the previous crash and into interactive menu
code, but user-visible rendering and a playable run still require confirmation.
The app remains open for inspection. Evidence:
`.build-device/compatibility-runs/game-v12-normal-1/`.

Remaining observed warnings include a particle program exceeding ANGLE's
16 vertex texture units, Compatibility renderer sub-emitter restrictions, a
font-path lookup failure, and Sentry native SDK initialization. None is shown
causing termination in this run; their visual or gameplay impact remains open.

## Build 12 follow-up: visible game with alternating corrupt frames

The user confirms the game is visible, but it strobes between ordinary colors,
apparently inverted colors and black. Visual acceptance therefore **fails**;
menu initialization and earlier pixel tests do not establish a rendering fix.
The ordinary run's later native log is preserved as
`.build-device/compatibility-runs/game-v12-normal-1/madeira-log-strobe.txt`.
It confirms the optional precise-buffer-dirty and extended tile-store paths
are off, foveation is unavailable, and the prior BC7 assertion is absent.
Later background-execution GPU permission errors are present and must be
separated from the earlier observed flicker; they are not a demonstrated cause
of alternating colors during foreground rendering.

The pixel fixture now includes 160 queued frames through two offscreen render
targets, alternating color transforms and dynamically renamed uniform buffers,
followed by an inverse transform and a final display pass. Final colors must
remain `(64,128,192,255)` at checkpoints of both transform phases. Readback is
periodic instead of per-frame, avoiding the previous test's unconditional GPU
serialization. The Windows x64 fixture compiles with `-Wall -Wextra -Werror`.
It is staged and its uploaded executable hash was verified, but the device
launch timed out. A separate Metal frame-capture launch also timed out.
Neither new device test is claimed to have executed. Receipts are under
`.build-device/compatibility-runs/angle-async-v12-1/` and
`.build-device/compatibility-runs/game-v12-capture-1/`.

Next: run the queued postprocess fixture, then capture real presented game
frames and compare upstream render-target content with drawable content.
Investigate synchronization/resource lifetime and color/presentation state
from those results before choosing a corrective patch. The macOS singleton
view issue documented in [upstream DXMT issue 183](https://github.com/3Shain/dxmt/issues/183)
is not established here: this iOS shim retains each acquired layer, and the
current trace shows only one view acquisition for the game HWND.

The headset became available and the asynchronous postprocess fixture
**passed on device**, run `f4e34999-cd04-4693-b3c0-f661668da80f`. All 160 frames
complete; eleven periodic readbacks across both transform phases match
`(64,128,192,255)`, followed by clean teardown. This rules out the tested
uniform-renaming/postprocess pattern, not the entire presentation pipeline.
Evidence: `.build-device/compatibility-runs/angle-async-v12-2/`.

The first accepted game capture launch did not arm DXMT's capture state: in
addition to the platform capture environment, `dxmt_capture.cpp` requires
`MTL_CAPTURE_ENABLED=1` and an exact `DXMT_CAPTURE_EXECUTABLE=SlayTheSpire2`.
The omission was found in source and corrected for the next attempt. The game
log was retrieved after stopping the diagnostic app; live copies of the
growing log had failed. No trace or analyzed frame is claimed from that run.

The corrected capture launch timed out. A fresh process inventory identified
the remaining StikDebug process (3214) attached to the stopped WineVision
session; only that helper was terminated. The next attempt then failed with
CoreDevice error 4000: required XPC connection to `remoteService` unavailable.
The reset did not establish recovery. The user was asked to open WineVision
manually to restore the foreground app connection. Corrected attempt receipts:
`.build-device/compatibility-runs/game-v12-capture-3/` and `game-v12-capture-4/`.
No captured Metal frame or additional rendering correction is claimed.

Host review of the existing Metal compatibility hooks found library-container
repair and pipeline diagnostics, but no per-frame color inversion operation.
This source review does not rule out shader translation, GPU resource lifetime,
or Core Animation presentation; the next concrete discriminator remains the
real presented frame capture.

## Build 13: controlled packed-SDR presentation comparison

After the user opened WineVision manually, the corrected launch succeeded.
DXMT frame 300 was captured and the complete 391 MiB package was retrieved:
`.build-device/compatibility-runs/game-v12-capture-5/frame300.gputrace`.
Its metadata records one frame from the M5 Vision Pro. The user reports that
the whole game image changes together while the separately displayed cursor
stays normal.

The captured packed `RGB10A2Unorm` snapshots include a correctly colored full
main menu. The raw snapshots have a 256-byte capture header with format, width,
height and row pitch; decoding the 10-bit channels produces previews in
`game-v12-capture-5/texture-previews/`. The 1026×768 snapshots numbered 1319
and 1605 both contain menu imagery and fully opaque 2-bit alpha. This proves
valid image content exists at the sampled boundary; a single captured frame
does not rule out corruption on other frames. Xcode opened the trace but its
remote replay remained unavailable; no successful replay is claimed. The
diagnostic app and helper were stopped after capture, and the stalled Xcode
replay window was closed.

The fixture now explicitly requests and verifies either RGBA8 or RGB10/A2 EGL
configuration. The 10-bit case **passes on device** (run
`fa2092e9-f044-4901-8215-d101dad158b0`), including all 160 postprocess frames,
BC7, pixel checks and teardown. The user did not see its brief window, so there
is no visual steady/flickering verdict from this fixture.

Patch `0051-dxmt-sdr-presentation-format.patch` adds an explicit diagnostic
`DXMT_SDR_PRESENT_BGRA8=1` comparison. Only final packed RGB10/A2 presentation
in the sRGB SDR color space becomes BGRA8. The game backbuffer, shader source
format and offscreen targets retain their original precision. The drawable
and present pipeline select the same output format together, after any display
color-space override; disabled launches, HDR, linear/wide SDR and other formats
keep their original behavior. No default compatibility-profile change is made
until a real game trial establishes its effect.

The actual policy header passes ASan/UBSan over seven formats and six color
spaces, including enabled/disabled and SDR/HDR transitions. Prepared source
comparison finds only the presenter and its new policy header differ from
build 12. Unchanged native archives and guest farms are bound by hashes; the
graphics closure and receipts are rebuilt. Evidence:
`.build-device/compatibility-v13-reuse.json`, `compatibility-v13-sdr-policy.log`,
and `compatibility-runs/angle-10bit-v12-1/`.

The host ran out of disk space during preparation. Superseded generated
compatibility source caches were removed after retaining their provenance and
checking for active symlink dependencies. The current source, signed candidates,
game backup, new capture and all test evidence remain available.

Build **0.1.0 (13)** compiles, passes strict signing, all 110 PE import checks
and 20 tool regressions, and is installed. The signed candidate and evidence
summary are in `dist/winevision-m5-2026-10-28-build13/`. The ordinary Steam launch
was accepted with a process-only `DXMT_SDR_PRESENT_BGRA8=1` comparison. It uses
the build-13 bundle, reaches runtime acceptance and stays open for visual
assessment. The normal saved compatibility profile is not changed.
Evidence: `.build-device/compatibility-runs/game-v13-bgra8-1/`.

The build-13 BGRA8 comparison **fails visual acceptance**: the user sees the
cursor and hears the game, but the game image is solid black. The native log
confirms `SDR presentation format 90 -> 80`; it contains no GPU validation
error or unhandled exception. The game still loads the menu and common assets.
This comparison is not promoted to the saved profile. Its diagnostic process
was stopped after visual feedback to retrieve the complete native log.

## Build 14: consecutive drawable pixels and presentation timestamps

A process-only `WVR_PRESENT_DIAGNOSTICS=1` observer records sixteen consecutive
presentations starting at frame 300. It intercepts both normal and minimum-
duration presentation methods, appends an output-texture readback to the same
command buffer, and retains its storage until completion. It does not force
a GPU/CPU wait. GPU status, exact pixel format, dimensions/stride, drawable ID
and actual presentation timestamp are written under a unique app-owned
`Documents/WindowsVR/PresentDiagnostics/<UUID>/` directory. Pixel copies are
limited to supported 4-byte formats and 8 MiB per frame; all other launches
leave the presentation methods untouched. The upcoming trial uses the original
output format (`DXMT_SDR_PRESENT_BGRA8=0`).

The native host fixture exercises both intercepted presentation entry points
on actual Metal command buffers, verifies completion-owned BGRA8 and packed
RGB10/A2 pixels and padded row stride, and passes strict compilation. Its
headless drawables correctly provide a zero presentation-time control.
Evidence: `.build-device/presentation-readback-probe/run-both.log`.
Build 14 compiles and passes strict signing. Its first device sample records
sixteen completely black RGB10/A2 drawables (frames 300–315), successful GPU
completion and zero presentation timestamps. Zero timestamps also occur in the
headless host control; they alone do not establish a layer presentation defect.
The retrieved Godot log reports the essential main menu loaded in 17.3 seconds
and an explicit `NGame.Quit` request, rather than a startup crash.

On October 29, a later sample at frames 900–915 again records sixteen entirely
black drawables after menu initialization. Evidence:
`.build-device/compatibility-runs/game-v14-late-2/decoded/summary.json`.
The prior retry ended before its later sample; the user confirmed accidentally
closing it and reported that audio sounded fixed while the image stayed black.

The user's increased crackling report is retained as a regression concern.
The first build-14 log has a 40 ms output shortage during startup and a late
audio wake of 72.5 ms. The October-29 retry, using the same 90 ms lead, has no
output shortage in its recorded pacing intervals, matching the user's report.
No persistent audio latency change is made from this intermittent observation.

## Build 16: compare presentation input and output

Build 15 was a host rebuild and storage consolidation; the headset retained
build 14. Historical build summaries and diagnostic evidence remain available,
but the exact build-12 app/source cache is no longer retained for a binary
baseline comparison. The receipt-verified build-13 graphics closure is retained.

The opt-in native observer now associates the final render pass's color target
and texture-0 input with its command buffer during the sixteen-frame sample.
It reads that input and the drawable in the same GPU submission, with bounded
allocation and completion-owned buffers. Matching the render target to the
presented drawable avoids treating an unrelated pass as the presentation input.
No generated DXMT sources or graphics artifacts are modified for this observer.
The host Metal fixture renders a known yellow input into a distinct orange
output in both BGRA8 and RGB10/A2, exercises both presentation entry points and
checks both input/output pixels, completion lifetime and padded row stride.
It passes strict compilation and execution; the decoder reports the expected
distinct colors. Evidence: `.build-device/presentation-readback-probe-v16/`.

Build 16 compiles, passes signing, packaging/core/app-contract tests and installs.
Two automated launch requests timed out; manually opening the app restored the
connection. The third request succeeds and records sixteen paired frames at
900–915. Every input contains the correctly colored, animated full main menu;
every drawable output is opaque black. Both are RGB10/A2, 1026×768, in the same
successful GPU submission. This localizes the observed black image to the final
presentation conversion, after game rendering. Evidence:
`.build-device/compatibility-runs/game-v16-paired-3/decoded/summary.json` and
`frame-0900.source.png` beside the black `frame-0900.png`.

## Build 17: initialize mobile display-query results

The mobile implementations of four display queries returned `STATUS_NOT_SUPPORTED`
without initializing output fields. `WMTQueryDisplaySettingForLayer`'s guest
thunk nevertheless copies the uninitialized version, color-space and EDR fields
into the presenter. The resulting arbitrary display override can select HDR
conversion and invalid brightness scaling. This is a concrete defect at the
boundary isolated by the paired capture; device testing must establish whether
fixing it restores a steady image.

Patch `0052-dxmt-mobile-display-query-outputs.patch` supplies deterministic SDR
description/EDR values, a false global override and a zero-version per-layer
override, and clears optional HDR metadata. Unsupported display-setting writes
remain unsupported. The desktop implementations remain unchanged. No default
output pixel-format or audio latency change is made.

The regression fixture compiles the actual mobile fallback bodies with their
real bridge structs. It exercises all four queries over 255 poison patterns,
checks complete SDR/no-override outputs and optional null metadata, and passes
ASan/UBSan; the previous implementation fails. The lossy-texture and presentation
format fixtures also pass. Authored-source comparison across 14,449 files finds
only the native Metal implementation differs from the retained build-13 runtime.
Nineteen unchanged archives are reused by hash; the complete native graphics
archive and four matching guest DLLs are rebuilt and staged with fresh receipts.
The pinned source checkout has unrelated local/submodule changes, so preparation
derives the validated baseline from the retained overlay, reverses its modern-
only Wine dispatch patch in isolation, and reapplies the complete profile.
The user's pinned checkout remains untouched. Evidence:
`.build-device/mobile-display-{baseline,fixed}-test.log`,
`compatibility-v17-reuse.json`, `compatibility-v17-base-derivation.json`,
`compatibility-v17-dxmt-build-2.log`, and `compatibility-v17-resource-stage.log`.

Build **0.1.0 (17)** passes the Release build, strict signatures, production
bundle validation, packaging, core and app-contract tests. Its 264 guest resource
hashes and 138 integration inputs verify, and it is installed on the headset.
The game initializes its menu in 15.9 seconds. The user confirms that the menu
is visible with steady colors. The sixteen paired frames at 900–915 now have
**identical decoded RGB hashes between input and output in every frame**, with
no GPU error. The former black output is corrected. Presentation timestamps
remain zero despite the user's steady visible image, so zero was not a reliable
failure signal on this platform. Evidence:
`.build-device/compatibility-runs/game-v17-fixed-1/receipt.json` and its
`decoded/summary.json`.

The app has restarted with `WVR_PRESENT_DIAGNOSTICS=0` and the original output
format for normal gameplay/audio assessment. No per-frame capture hooks are
installed in this run. User assessment of playing cards and audio is pending.
The signed current app is `dist/current/WineVision VR.app`; its build summary
records the device/menu result separately from full gameplay acceptance.

### First combat transition: executable pool exhaustion

The normal gameplay trial fails after selecting the first Act-1 stage: the user
reports a black loading screen that never returns and looping audio. The Godot
log completes combat asset preloading and stops at `Creating NCombatRoom` for
`NIBBITS_WEAK`. A copy of the current run save is preserved with the trial.
Restarting archives the native log, allowing a complete immutable transfer.

The native log shows the 640 MiB executable arena with 288 MiB tail reservations
and approximately 315 MiB of head use. Its head reserve rejects successively
smaller FEX code-buffer allocations from 128 MiB down to 1 MiB. FEX then takes its
deliberate `0xdead` allocation-failure fault in `CodeBuffer::CodeBuffer`; exception
state reconstruction waits while the thread still holds its translation lock.
Symbolizing the retained ARM64EC FEX DLL confirms both the allocation-failure
instruction and the subsequent `ResetToConsistentState` caller. This failure
occurs after the corrected presentation path and must not be reported as full
gameplay acceptance. The audio pacing log has no output shortages during the
stall; looping audio is consistent with the stalled game thread.

Evidence: `.build-device/compatibility-runs/game-v17-normal-1/receipt.json`,
`godot-stalled.log`, `madeira-stalled-archived.txt`, and `current_run.save`.
An explicit process-only `FEX_MULTIBLOCK=0` trial tests reduced translation
duplication before changing persistent profile defaults or arena allocation.
Its launch timed out, and the subsequent process inventory also timed out;
there is no accepted single-block game run yet. The user has been asked to open
WineVision manually again. Do not infer a result from the failed launch.

A pristine local source checkout was reconstructed from pinned Git objects in
`.build-device/pinned-madeira-pristine/`, including all 25 nested repositories,
and passes `verify_source_checkout`. This avoids the unrelated modifications in
the user's original source cache for subsequent fresh profile preparation.
It shares read-only object storage with the original repositories; their
working files were not reset or modified. Evidence:
`.build-device/compatibility-pristine-source.log`.

## Build 18: scoped executable-arena capacity

The user clarified that the subsequent retry hangs on a black screen. The host
process remains alive. Its archived runtime log reproduces the 640 MiB pool
exhaustion, followed by FEX's deliberate allocation-failure fault and repeated
exception-delivery failures. No new native WineVision crash report was found in
the retrieved listing. Evidence:
`.build-device/compatibility-runs/game-v17-user-retry-crash/`.

The single-block request reports a device-service timeout, but WineVision
subsequently accepts the launch and reaches the menu in 16.7 seconds. The user
again reports a black first-stage scene. This comparison does not establish a
solution and is not persisted. Its subsequently archived native log
(`madeira-singleblock-archived.txt`, runtime start 14:32:51) confirms the same
allocation refusals down to 1 MiB and deliberate failure fault. The file named
`madeira-previous-session.txt` belongs to the preceding session.

Patch `0022-madeira-scoped-jit-pool-size.patch` adds an explicit
`WVR_JIT_POOL_MIB` host setting. The parser accepts 640–1024 MiB in 64 MiB
increments and falls back to the original 640 MiB for absent, malformed,
out-of-range or overflowing input. One validated size is used for the debugger
allocation, RW alias and exported bounds. Slay the Spire 2 requests 896 MiB in
its scoped profile, preserving explicit manifest/process overrides; other games
retain their ordinary allocation. The native plugin applies this host setting
before `fex_initialize`, rather than during the later guest-environment handoff.
Pool collision checks and the head reserve remain unchanged.

The actual policy passes ASan/UBSan over the complete 0–2048 input range and
invalid/overflow cases. Swift profile checks cover game scope and both override
precedence paths. Fresh source preparation uses the verified pristine checkout.
Comparison across 14,449 authored files finds only `app/Madeira/FEXBridge.mm`
differs from build 17. The bridge is recompiled by Xcode; nineteen unchanged
archives are reused by hash and the graphics closure is rebuilt with fresh
receipts. Device allocation and gameplay acceptance remain pending.
Evidence: `.build-device/compatibility-v18-jit-policy.log`,
`translation-policy-v18/run.log`, `compatibility-v18-source-comparison.json`,
`compatibility-v18-reuse.json`, and `compatibility-v18-dxmt-build.log`.

The first Xcode attempt catches a type mismatch: launch environments are a
vector of pairs, so early lookup uses `std::find_if`. After correcting the
app source, a fresh `runtime-compatibility-v18-final` profile and complete
graphics rebuild refresh its integration-input receipts. Authored prepared
sources match the first candidate exactly; no receipt freshness checks are
bypassed. Final evidence uses the `compatibility-v18-final-*` files.

The corrected build 18 passes Release compilation, strict signatures, production
bundle checks and packaging/core/app-contract tests; 264 guest resources and
139 integration inputs verify. It installs successfully and launches without a
CLI timeout after the old WineVision session is explicitly stopped. The game
reaches its menu in 20.9 seconds using the saved game profile, with capture
disabled and normal multiblock translation. The user confirms **combat loads
and cards work**, passing the first-stage trial that previously stalled. Evidence:
`.build-device/compatibility-runs/game-v18-pool896-1/` and
`dist/current/build-summary.json`. A live native-log transfer failed, so no direct
live allocation-size measurement is claimed. Acceptance covers the menu, first
combat loading and card play; an entire run and later acts have not been tested.
The game is left running with capture disabled. The profile and installed build
retain both fixes for ordinary launches.
