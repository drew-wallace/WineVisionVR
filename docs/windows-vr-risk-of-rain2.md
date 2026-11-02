# Risk of Rain 2 startup failure — October 30, 2026

The physical headset's retained runs at 13:41 and 14:35 both exhaust the
640 MiB executable-code pool before graphics initialization completes. The
14:35 runtime reports a 416 MiB tail reservation and about 222 MiB of image
allocations, then refuses the D3D11 image's approximately 3.6 MiB allocation.
DXGI and subsequent image loads fail the same way.

Unity 2021.3.45f2's `Player.log` reaches `GfxDevice: creating device client`,
reports that it cannot load the Direct3D DLLs, and records `Crash!!!`. This
explains the desktop appearing before any game screen. No matching WineVision
system crash report or new jetsam event was present in the collected listing;
the guest's own crash is recorded.

Build 48 extends the existing measured-game code-space policy to Steam app
632360: disable persistent FEX code caching by default and request an 896 MiB
JIT pool. Explicit manifest/profile and inherited process overrides retain
precedence. Other games retain their existing policy. The final launch manifest
also fills missing compatibility defaults after saved-profile reconciliation,
so an older saved Risk of Rain 2 entry receives the repair.

The translation-policy executable checks both affected games, unrelated games,
and explicit override precedence. A successful build or policy check alone
does not establish successful Risk of Rain 2 rendering or gameplay.

Device evidence and build/test receipts are retained locally under
`.build-device/risk-of-rain2-startup/`: `game-runtime.txt`,
`game-runtime-earlier.txt`, `Player.log`, `launcher-log.txt`, and
`crash-list.json`. Further physical results belong alongside that evidence;
the baseline logs must not be overwritten by a retry.

## Physical follow-up

Build 48 loaded Direct3D 11 feature level 11.1 on the M5 GPU, initialized Mono
and input, and created a 1920×1080 game window. It then exhausted FEX's separate
16 GiB host-address arena with roughly fifty live 50 MiB lookup tables plus
other translator allocations. A process-only `FEX_DISABLEL2CACHE=1` comparison
used the existing 2 MiB L1-only layout, passed that failure, initialized Wwise
audio, then exited with a C++ exception immediately after Rewired requested
`Windows.Foundation.Metadata.ApiInformation`: `wintypes.dll` was absent.
The later illegal-instruction fault occurred during process cleanup and does
not establish the cause of that earlier exception.

Build 49 makes the L1-only setting the default for app 632360 only, preserving
explicit profile/process overrides. It also builds and packages Wine's pinned
ARM64EC `wintypes.dll`; the package validator rejects a missing or ARM64-only
copy. Native archives and all existing guest DLLs are reused with verified
hashes. Device logs for the comparisons are `runtime-48.txt`,
`game-runtime-48-l1.txt`, `Player-48.log`, and `Player-48-l1.log` in the evidence
directory. Passing these earlier initialization stages does not establish
successful gameplay.

## Title-screen host crash — October 31

Build 50's 00:18 and 00:24 runs fail in the same order: Metal rejects three
render pipelines with `Function requires stage_in attributes but no descriptor
was set`, then the native render-command encoder faults in the M5 GPU driver
while drawing. The first fault reads address `0xa00` through a null register;
the caller is `_MTLRenderCommandEncoder_encodeCommands+0x1b4`. Subsequent fault
delivery loops consume memory and exhaust the translator's host-address arena.
Those later allocation failures are secondary in these captures. No matching
WineVision system crash or new jetsam report was present when collected.

The D3D11 submission callback already avoids binding a failed pipeline, but it
leaves the previous binding marked ready and still submits the draw operation.
Local integration patch 0053 clears that readiness after each failed pipeline
resolution and gates all fourteen direct, indexed, instanced, indirect,
geometry, and tessellation draw paths on the resolved pipeline. A later valid
pipeline resumes drawing. Compute and copy operations keep their own paths.

Build 51 carries this guest-only repair. The production submission callbacks
pass immediate/deferred queue regression cases under ASan/UBSan: no initial
pipeline, failure after a successful bind, repeated failures, and recovery on a
new valid bind. Both affected ARM64EC context translation units are rebuilt;
native archives and other guest outputs are reused after hash verification.
This prevents invalid draws; it does not establish support for the rejected
shader/input combinations or prove complete game rendering.

Evidence and build receipts are retained under
`.build-device/risk-of-rain2-title-fix/`; baseline logs are
`game-runtime-title-0018.txt`, `game-runtime-title-0024.txt`, and
`Player-title-crash.log` in `.build-device/risk-of-rain2-startup/`.

## Build 51 follow-up: independent address-arena exhaustion

The user confirmed another title-screen app exit. Its complete runtime log
shows the pipeline rejections still occurring, but no repeat of the native
AGX `0xa00` fault. Later, a 512 MiB reservation fails inside FEX's 16 GiB host
address arena, followed by a failed 16 MiB allocation and a translator write
through `0x800000`. The runtime then terminates after repeated fault delivery.
Build 51 therefore passed the earlier invalid-draw fault, but did not resolve
the overall launch failure.

Build 52 adds `-job-worker-count 2` to this game's Steam child launch. This is
Unity 2021.3's documented worker-count control, scoped to app 632360. It is a
comparison intended to reduce translated thread/heap pressure; successful
loading and gameplay must be established physically before calling it a fix.
See [Unity's worker-count documentation](https://docs.unity.cn/2021.3/Documentation/ScriptReference/Unity.Jobs.LowLevel.Unsafe.JobsUtility.JobWorkerMaximumCount.html).

Build 52 also exited. Its full log confirms `-job-worker-count 2` reached the
child process, but the shared 16 GiB arena still filled. The next 16 MiB request
failed and the same translator null-offset write followed. The native AGX draw
fault did not recur. The complete log is retained under
`.build-device/risk-of-rain2-title-fix/after52-latest/runtime52-complete.txt`.
The shared log was again restored and byte-verified after retrieval.

Build 53 attempts a real 32 GiB native PROT_NONE arena for this game through
`WVR_FEX_ARENA_GIB=32`. Patch 0025 publishes the range only after successful Mach
reservation and Wine registration. Failed allocation/registration falls through
to the existing ladder; configured `arena-mb` caps and the arena disable switch
still apply. Other games keep their existing default. Explicit manifest/process
overrides take precedence. Classic guest swap and delayed free also exclude
the actual shared range when it extends below the old fixed boundary. This
reserves address space without committing the full range as physical memory.
The production reservation function passes allocation/registration failure,
cleanup, cap, malformed override, default, disable and repeated-call tests under
ASan/UBSan. The device reserved `[0x7800000000,0x8000000000)` (32 GiB),
registered it FEX_ONLY and handed it to the translator. Two runs reached
`BaseMainMenuScreen: OnEnter()`; the second also created a Steamworks lobby.
Neither full runtime log contains the prior failed arena request, native AGX
fault, or recursive unhandled fault. StikDebug records `W00` (exit status zero)
for both at 01:40:09 and 01:44:01, unlike builds 51/52's `W4c` fault-handler
exit. No matching new system crash or jetsam report appeared. The user subsequently confirmed that build 53's title/menu stays open and that
both exits/restarts were manual. The reported startup/title crash is resolved
in build 53; gameplay remains unverified. The reply to the older build-52
question arrived at the same time and also described an open menu; it is not
used to override build 52's separately captured allocator-fault evidence.

The complete device logs are `runtime53-first-complete.txt` and
`runtime53-second-complete.txt` under the title-fix evidence folder. The first
was recovered from its rotated archive alias and restored as a byte-verified
independent copy; the active second log was untouched during that retrieval.
After the second process exited, its shared alias was likewise restored and
byte-verified. Timestamped originals and all bytes were retained. Debugger exit
records are saved in `after53-debugger/stikdebug.txt`.

The failed build-51 run is retained in
`.build-device/risk-of-rain2-title-fix/after51-afc/runtime51-complete.txt`.
Its two log names were hard links, and both CoreDevice and AFC refused to open
them while linked. Removing the shared name temporarily allowed the timestamped
original to be copied. AFC could not recreate the hard link, so the shared log
was restored as an independent, byte-verified copy; the timestamped original
and all bytes were retained. The recovered per-attempt journal and game log are
saved alongside it. No matching system crash or new jetsam report was found.

## Recurring audio static and recovery candidate

The user reports that headset-wide static begins spontaneously in Risk of
Rain 2. Closing the window stops the distortion; reopening brings it back.
Force-quitting clears it until a later recurrence. This reproduces the issue
without the Slay the Spire 2 Tab control. The earlier output reset did not
restore clear sound.

Retrieved logs are preserved under `.build-device/audio-ror2-followup/`.
The launcher records successful native reset statuses at 23:32:31 and
23:32:34, with the same 48 kHz speaker route, followed by backgrounding at
23:32:40 and reactivation at 23:34:27. Native logs confirm the stop/reset/start
calls returned zero. Those statuses establish API success, not audible recovery.
The run also contains a background pause and an unexplained 53.9-second gap;
neither establishes the cause of the static.

Build 50's candidate extends output recovery to stop, uninitialize, initialize,
and restart the existing RemoteIO unit. This releases initialized output
resources that AudioUnitReset leaves in place. WASAPI clients, ring positions,
the game session and the one RemoteIO instance are retained. A failed stop
prevents further teardown; failures propagate, and a failed initialization
leaves output stopped for a later retry. The UI asks the user to check the
sound after a successful output restart. No audible repair is inferred from
the API return code.

`test_audio_recovery.py` executes the production function with sanitizer checks
for ordering, failure recovery, idle clients and preserved ring state. Its
`--simulator` option also verifies resumed callbacks after three reinitializations
of a real RemoteIO unit on visionOS 27. Both pass. This remains a recovery
candidate; the trigger and physical effectiveness require further evidence.

## November 1: player and enemy health-bar fills

The user reports missing colored fills in both player and enemy bars. A similar
black/missing-bar problem is documented by the author of
[MetalSafeBars](https://github.com/Krabik6/MetalSafeBars), distributed as
[LevTeam-MacosHealthbarsFix 1.0.27](https://thunderstore.io/c/riskofrain2/p/LevTeam/MacosHealthbarsFix/).
This is a game-local cosmetic compatibility repair, not a general DXMT fix.
Its published DLL was decompiled and checked against the public source: it
finds RoR2.UI.HealthBar objects and replaces image materials/sprites, mask and
fill presentation, with a font-material refresh. It does not change health
values or save data. Its actual visual behavior on visionOS remains to be
confirmed. Earlier stage_in pipeline errors remain a separate graphics lead;
no DXMT patch was made on an unproven association with these bars.

The headset game had no existing BepInEx, winhttp.dll or doorstop_config.ini.
The published BepInExPack 5.4.2121 and health-bar plugin were installed locally:
24 new files, 1,809,515 bytes. Every file was read back byte-for-byte. Existing
files were not replaced. The native AMD64 Doorstop winhttp.dll was installed
last, after its managed loader and plugin were complete. Doorstop's managed
debugger is disabled. This Madeira Wine loader searches the game folder and
loads an available native DLL directly; no global DLL override was changed.
The game has the required Mono/.NET Standard and Unity UI/TMP assemblies.

Package identities:

- BepInExPack 5.4.2121 SHA-256:
  `26bf7c65ade04e1dee479b6e8ec29725167b19a6a75425bba2d7e05095d7314a`
- MacosHealthbarsFix 1.0.27 SHA-256:
  `f3028a27c86cadee82ed2d0780f2bb53fd07736b698641a8b4a4308e999f094b`

The full installed-file hash receipt, reviewed source, decompilation, original
packages and local rollback helper are retained in `.build-device/ror2-healthbars/`
and `.build-device/visionos-pair-host/`. Rollback verifies all installed bytes
before deleting any package file, removes the loader first, and retains game
files plus generated logs/configuration. The helper was compiled, not executed.
No WineVision app build or runtime archives changed for this repair.

WineVision was not running when the agent attempted a test launch. CoreDevice
launch failed to complete, including a bounded 15-second retry, and no loader
log had appeared in the first capture. The user was asked to launch the game
on the headset to establish loader activation and actual bar visibility.
Installation is verified; loader activation, restored bar visibility and
multiplayer compatibility are not yet established.

A direct RSD AppService launch with `terminateExisting=false` also timed out
at its 20-second bound. It did not report a successful launch. The remaining
check requires opening the app on the headset. The pending user prompt asks
for visible fill in both player and enemy bars after starting a run.

### First physical test: plugin dependency missing

The user reported both bars still black/empty. The captured Player.log confirms
Doorstop and BepInEx 5.4.21.0 started, patched RoR2, and initialized the
chainloader. It then rejected MetalSafeBars because `Newtonsoft.Json` could not
be resolved. Thus the first visual test did not exercise the material repair.
The game's Managed folder has no standalone Newtonsoft.Json.dll.

A separate shutdown trace shows recursive `LoggedTextWriter.WriteLine` calls
through BepInEx's optional ConsoleSetOutFix, ending in StackOverflowException.
The BepInEx log grew to 8,521,045 bytes. Head/tail excerpts and the game's own
log are retained in `.build-device/ror2-healthbars/after-user-test/`.

The follow-up installs the official Newtonsoft.Json 13.0.4 netstandard2.0 DLL
in BepInEx/core. BepInEx's actual LocalResolve/TryResolveDllAssembly implementation
loads dependencies by simple name and can resolve the older requested assembly
version from this compatible package. The NuGet package SHA-256 is
`f09081d457405baf35a973fa0c50d6bf272ed683f2568c5a620a49da952f6529`;
the DLL is 717,736 bytes, SHA-256
`12246aa5e14245cbd1a0b8794851defd46e6d782c60eb650ba5aa90ef8447eee`.
Its deployed bytes were read back and verified.

The generated BepInEx.cfg is backed up alongside it as
`BepInEx.cfg.wvr-healthbars-original`. Only `ApplyRuntimePatches` changes from
true to false. This bypasses the optional ConsoleSetOutFix and Unity runtime
patches; the preloader assembly patching/chainloader and normal log outputs
remain enabled. The backup and updated config were byte-verified. Rollback
now verifies all 25 package files plus the config/backup before removing the
loader and restoring the prior generated config. It was compiled, not run.
No original game assemblies, profiles or save files were changed.

A fresh headset launch is needed to establish that the plugin now loads and
restores the bars. The remote launch request again timed out; the user was
asked to restart when ready. No successful follow-up loading or visual repair
is claimed yet. Package: [Newtonsoft.Json 13.0.4](https://www.nuget.org/packages/Newtonsoft.Json/13.0.4).

### Dependency follow-up: plugin now loads

After the user fully restarted and reached the menu, the fresh BepInEx log
records `Loading [MetalSafeBars 1.0.0]`, `[MetalSafeBars] Loaded` and successful
chainloader completion. The missing dependency error is absent. The plugin
reports zero active health bars at the menu; actual restoration still requires
starting a run and observing changing player/enemy health fills. This capture
is retained in `.build-device/ror2-healthbars/restarted-at-menu/`.

The same follow-up run subsequently records repeated `Patched HB (Init)`,
`ChildrenHashChanged` and `ChildrenChanged` events, with at least four health-bar
objects tracked. The repair is therefore confirmed operating on in-run bars,
not merely present in the plugin directory. This evidence is in
`.build-device/ror2-healthbars/in-run-check2/`. Actual colored/visible fill
restoration remains pending the user's visual observation.

The user then confirmed **both bars work** after the in-run check of player and
enemy health fills. The health-bar issue is resolved for this headset setup
with the game-local repair, Newtonsoft.Json dependency and loader configuration
recorded above. No further restart or session interruption was performed.

### Automatic install and launch repair

`RiskOfRain2HealthBarRepair` runs after Steam app 632360 finishes an install or
update and before its selected Steam launch starts Wine. Other Steam titles
return without filesystem or network work. The signed app ships only the
`GameCompatibility/RiskOfRain2/healthbars.json` recipe, containing pinned URLs,
archive sizes/hashes and all 25 deployed member sizes/hashes. Third-party DLLs
are fetched on the headset from Thunderstore and NuGet, not bundled in WineVision.

The repair adopts byte-matching existing files and seeds a persistent cache at
`Documents/WindowsVR/CompatibilityAssets/RiskOfRain2Healthbars/healthbars-1/Assets`.
This cache is outside Steam's game directory, so deleting/reinstalling the game
does not remove it. Missing game files are restored from verified cache bytes;
only packages needed to fill cache misses require a connection. If WineVision's
own data is deleted too, the packages must be downloaded again.

Every game destination and loader configuration is preflighted before network
work. Different existing loaders or DLLs, case collisions and symlinks are
preserved with an error. Cancellation and an active Wine session prevent
publication. Files are staged locally and exclusively renamed, with winhttp.dll
published last. A partial publication is completed on the next attempt. Matching
files are never rewritten. The required `[Preloader] ApplyRuntimePatches = false`
setting is merged into BepInEx.cfg, preserving other settings, UTF-8 BOM and line
endings; prior configuration bytes are backed up by hash in the persistent
`ConfigBackups` directory. No game assemblies or save data are changed.

The filesystem contract tests execute the production Swift implementation with
ZIP fixtures: clean install, repeat launch, adoption of a manual repair, offline
reinstall, missing dependency restoration, configuration backup/preservation,
conflicting mods, case collisions, symlinks, cancellation and runtime exclusion.
The same harness also passed locally against the exact three upstream archives
and all 25 production asset pins. A separate real URLSession download probe
checks the current HTTPS redirect chain and pinned archive/member contents.
These checks use disposable game folders; they do not uninstall the user's game.
