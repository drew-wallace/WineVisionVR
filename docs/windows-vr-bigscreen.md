# Bigscreen startup failure — November 1, 2026

The physical headset's 22:15 and 22:16 attempts exhaust the 640 MiB
executable-code pool during VR initialization. Both logs first refuse a
roughly 45 MiB image allocation with about 209 MiB already used and 416 MiB
reserved at the tail. Later library loads fail repeatedly and the guest
crashes. Bigscreen's Unity log reaches Direct3D 11 feature level 11.1 on the
M5 GPU, fails Oculus initialization, then reports
`VRInitError_Init_VRClientDLLNotFound` from OpenVR before `Crash!!!`.

The captured runs both use launch option 2. The later option-0 attempt fails
in Steam preparation with `disconnected` before runtime acceptance; it is a
separate failure and does not establish an OpenVR result for that option.

Build 63 extends the existing measured-game code-space policy to Steam app
457550: disable persistent FEX code caching and request an 896 MiB JIT pool.
Explicit profile/manifest and inherited process overrides retain precedence.
The final launch manifest already fills missing defaults after saved-profile
reconciliation, so existing Bigscreen profiles receive this change too.
Build 63 does not give Bigscreen Risk of Rain 2's separate thread/cache/arena settings.

Device evidence is retained under `.build-device/bigscreen-startup/`, including
the two timestamped runtime logs, `output_log.txt`, launcher milestones, and
per-attempt journals. These were copied without altering remote logs.
Policy tests cover defaults, saved environments, explicit overrides, and
unrelated-game exclusion. Successful compilation and installation do not
establish that Bigscreen passes VR initialization or renders successfully;
that requires a physical launch retry.

## Build 63 policy follow-up on build 64 — November 2

The attempt journals identify build 64, which retained build 63's Bigscreen
policy. The 00:00 launch (Steam option 0) passes the earlier executable-code failure:
the runtime confirms the 896 MiB pool, loads `vrclient_x64.dll`, and reaches
OpenVR initialization. No `[jit-pool] EXHAUSTED` event occurs in the retained
runtime log. It then fills the separate native 16 GiB translator arena. The
51st live 50 MiB lookup-table allocation returns null (`STATUS_NO_MEMORY`),
followed immediately by a read at `0x1000000` inside `libarm64ecfex.dll` and
repeated exception delivery. The user reports the app exits.

The system crash listing contains a StikDebug CPU-resource fatal report at
00:00:43 and no matching new WineVision crash report. This does not establish
the exact mechanism of the reported app exit. The later 00:02 Other VR attempt
fails during Steam preparation with `disconnected`, before runtime acceptance;
it cannot be treated as a second capture of the arena failure.

Build 65 extends the existing L1-only lookup-cache policy and 32 GiB native
arena request to Bigscreen. This reduces each thread's lookup table from
50 MiB to 2 MiB and requests additional address space through the already
packaged native reservation code, with its existing failure fallback. Explicit
profile/process overrides retain precedence. No Unity worker-count change is
included. Tests cover the new defaults, old saved environments, override
precedence and unrelated-game exclusion. Build 64's separate health-bar repair
remains included in the app sources.

Evidence is preserved under `.build-device/bigscreen-startup/after63/`, including
`Bigscreen.exe-2026-11-02_00-00-30.txt`, `madeira-log.txt`, `output_log.txt`,
launcher milestones, attempt journals and the system crash listing/report.
Successful build and installation of build 65 do not establish successful
Bigscreen rendering; a physical retry is still required.

## Build 65 logo stall and skybox repair

The 00:18 build-65 run confirms the 32 GiB arena and 2 MiB L1-only thread
tables. It contains neither the earlier executable-pool exhaustion nor
`STATUS_NO_MEMORY`. Unity initializes OpenVR, creates the eye render textures,
and discovers both controllers. The user sees the Bigscreen logo, then a stall.

OpenComposite's log identifies the blocking call at 00:18:55. Its first skybox
request submits a quad layer that the projection-only WineVision runtime
rejects with `XR_ERROR_LAYER_INVALID` (-23). The next request uses a 1024×1024
BC1 texture (DXGI format 71); swapchain creation returns
`XR_ERROR_FEATURE_UNSUPPORTED` (-8), and OpenComposite opens its fatal error
dialog. Wine logs the dialog and its Abort/Retry controls while the game log
stops advancing. This is a startup stall, not another captured memory crash.

Build 66 adds OpenComposite patch 0012. On the `WineVision VR` runtime it
returns `VRCompositorError_RequestFailed` from `SetSkyboxOverride` before
initializing graphics resources, changing frame state, or calling any frame
wait/begin/end functions. Loading-screen skyboxes remain unavailable, while
ordinary eye submission keeps its existing path. Other runtime names and
unavailable runtime-property queries retain upstream handling.

Both x64 and ARM64EC OpenComposite libraries are rebuilt from the pinned
source with the complete patch sequence. The production-function regression
uses generated OpenVR interfaces and runs under ASan/UBSan; it checks repeated
requests, null/invalid handles, frame-state preservation, and other-runtime
behavior. Private C++ dependency checks pass for both DLLs. The staged native
OpenVR/OpenXR pair has a new matching receipt. Native Wine/FEX/DXMT archives
and their historical receipts remain unchanged; a separate OpenVR rebuild
receipt records the new source/patch and artifact hashes. The local app build
validates that explicit replacement alongside the retained native closure.

Evidence, build logs and test output are retained under
`.build-device/bigscreen-startup/after65/`; new guest sources, build outputs and
staged resources are under `.build-device/bigscreen-startup/skybox66/`.
Build 66 guards the skybox entry point. Successful game loading beyond the
logo remains subject to a headset retry.

## Build 66 follow-up: second upload path

The 00:31 build-66 attempt logs the skybox `RequestFailed` response, confirming
patch 0012 executes. Immediately afterward a separate overlay upload requests
the same 1024×1024 BC1 texture. That path still invokes the D3D11 compositor,
hits `XR_ERROR_FEATURE_UNSUPPORTED` and opens the hidden OpenComposite error
dialog. The first repair missed this second entry point. No code-pool or
translator-arena allocation failure appears in this capture.

Build 67 adds patch 0013. A shared runtime predicate gates skyboxes and optional
overlay uploads on the projection-only WineVision runtime. Texture, raw and
file overlay calls validate the handle, then return `RequestFailed` without
dereferencing the supplied resource, mutating overlay textures, initializing
graphics, registering compositors or uploading. Layer assembly preserves the
scene projection, omits unsupported overlays/keyboard layers, and leaves
controller input with the scene. Other runtime names and failed property
queries retain upstream paths. This does not add overlay rendering support.

The production entry-point tests for both skyboxes and overlays pass under
ASan/UBSan using generated OpenVR interfaces. They cover repeated requests,
invalid handles/pointers, old overlay state, projection preservation, keyboard
input routing and the original upload/layer assembly on other runtimes. Both
guest architectures are rebuilt and their dependency closures verified. The
separate OpenVR build receipt binds both patches and output DLL hashes; native
archives and historical runtime receipts are retained unchanged.

Build-66 evidence and build-67 checks are saved under
`.build-device/bigscreen-startup/after66/`; staged build-67 resources are under
`.build-device/bigscreen-startup/layers67/`. A diagnostic headset launch is
planned after installation; its results must be recorded separately from the
synthetic checks and the user's visual confirmation.

## Build 67 physical diagnostic: shared browser texture failure

The 00:56 diagnostic run passes both loading-layer guards and reaches later
Bigscreen initialization. The game then reports failed browser texture and
shader-resource-view creation (`0x80004005` and `0x80070057`) before crashing
inside `VuplexWebViewWindows.dll`. The native runtime identifies the first
failure: `DeviceTexture: Failed to register mach port for shared texture`.
The mobile Winemetal bootstrap handlers explicitly return
`STATUS_NOT_SUPPORTED`; the plugin subsequently dereferences its missing
texture. The capture also reports missing Media Foundation engine classes
and a Unity TLS certificate error. Those are separate compatibility issues;
their resolution is not established by the texture repair.

Build 68 installs an app-local name registry at the pinned, writable Winemetal
dispatch slots 121/122 before Wine starts. All virtual Windows processes run
inside the same native task. Registration retains one Mach send right, lookup
returns a newly retained send right, and dead receive endpoints are rejected
and removed. Duplicate registrations are idempotent, conflicting names fail,
and the registry is capped at 4096 names. Rights live for the app process,
matching its single runtime session; no system bootstrap service is registered.
The installer checks dispatch count 149, transport ABI 1 and writable data
before replacing the two mobile handlers. Guest/native graphics archives and
their historical receipts are unchanged; the bridge is compiled into the app.

`windows-vr-tools/test_shared_resource_ports.py` runs the production registry
under ASan/UBSan with real Mach ports, exact reference-count cleanup, concurrent
lookups, dead names, capacity and invalid/read-only dispatch tables. A real
Metal texture is exported, registered, looked up and imported; GPU write/readback
pixels match through both texture handles. The optional `--winemetal-source`
argument also verifies dispatch indices and the 136-byte guest request layout
against the pinned sources. Evidence is under `after67/`; build-68 checks are
under `.build-device/bigscreen-startup/shared68/`. Device behavior still needs
a diagnostic launch after installation.


## Build 68 headset result and build 69 changes

The user heard room audio behind the loading logo, then the game crashed.
The final OpenComposite log rejects 2880x2688 eye submissions with OpenXR -25:
Bigscreen raises its render scale to 1.5 while the native target is 1920x1792.
Patch 0014 resamples the complete eye image to the runtime's recommended extent
before swapchain allocation and submission. Both guest architectures compile;
the production normalization/UV regression passes with ASan and UBSan.

The later exception is in BigSoup.dll at RVA 0x8832d. Its desktop capture code
requests IDXGISurface1, ignores E_NOINTERFACE, and dereferences the null surface
before GetDC/BitBlt. DXMT patch 0054 implements aggregated IDXGISurface/1 on
single-mip, single-array 2D textures. GDI-compatible BGRA textures expose a
DIB-backed DC; ReleaseDC uploads its pixels, and GetDC(FALSE) reads existing
GPU contents back first. COM identity and texture ownership are preserved.
The guest D3D11 library is rebuilt with the retained pipeline repair; native
Wine/FEX/DXMT archives are reused and individually verified, not rebuilt.

`windows-vr-tools/probes/gdi_surface_probe.cpp` checks real GPU/GDI pixel
transfers, preserving reads, partial updates, empty updates, COM identity and
invalid acquisitions on the headset via the diagnostic mapping-probe route.
Build 69 passed the physical headset GDI probe, including exact GPU pixel
readback and preserving updates. Its game launch exposed an incorrect aggregate
initializer in patch 0014 (OpenVR orders fields uMin,vMin,uMax,vMax). Build 70
corrects it; the regression now includes the actual upstream OpenVR header
and fails against the incorrect initializer. Build 70 gameplay is pending. Local evidence is retained under
`.build-device/bigscreen-startup/gdi69/` and `after68/`.


Build 70 is installed and was launched automatically. The current game log
reaches private-room initialization, and OpenComposite tracking continues
through 01:54:54 local, without the earlier bounds abort or EndFrame -25.
The user has not yet confirmed that the room is visible. TLS verification and
Media Foundation factory warnings remain separate compatibility limitations.
The saved build's supplemental resource-stage manifest was refreshed and
re-signed; strict signatures and the production bundle validator pass. All
runtime DLLs used in the headset session remain byte-identical.


## Performance diagnostic retry

The user confirmed the room is visible in build 70, with sound, but reported
very long image freezes and an audio-device setup prompt. Controllers were off.
The app's PSVR2 Sense provider supports discovery during a running session;
Bigscreen menu interaction still needs a physical controller check.

A fresh build-70 launch with process-only WVRPerformanceDiagnostics enabled
succeeded after the device tunnel reconnected. The compositor presents around
106–120 frames/sec. Fresh guest-frame transfers reach roughly 35–42 frames/sec
in several room windows, but later fall as low as 0.2/sec in a five-second
window before recovering. This confirms intermittent stalls, rather than
establishing a sustained performance fix. GPU queue times also rise during
some stalls; CPU and graphics synchronization remain under investigation.
Per-process Time Profiler attachment did not find the app, and all-process
recording did not progress past startup; that attempt was terminated.
Evidence: `.build-device/bigscreen-startup/performance70/retry/`.


## Settings freeze and diagnostic build 71

The user confirmed smoother room rendering and working controllers after the
retry, then reported a freeze when entering Bigscreen settings. Fresh transfers
stop around device-log time 11:08:34; GPU commands and presentation continue.
The OpenComposite XR_ERROR_SESSION_NOT_RUNNING at 11:09:27.779 follows the
app's stop request at 11:09:27.695 and is not evidence of the original cause.
Build 71 preserves all runtime DLLs and makes the existing five-second native
frame-queue counters available with performance diagnostics, including
submitted/acquired/completed/dropped/queued frame counts. This is diagnostic
instrumentation, not a claimed settings-freeze fix. Evidence is under
`.build-device/bigscreen-startup/settings-freeze70/`.


## Build 71 follow-up and microphone candidate 72

The user reported that revisiting Settings worked, controller input worked,
and voice input had no device. Joining a home-theater room then crashed.
The crash is a null destination in BigSoup's video-packet reassembly memcpy
(RVA 0x23e701, caller 0x970f9), distinct from the prior IDXGISurface1 fault.
Theater-room recovery remains unresolved; evidence is under
`.build-device/bigscreen-startup/theater71/`.

The pinned native audio driver explicitly exposed render endpoints only.
Candidate 72 adds an authorized microphone endpoint and WASAPI capture buffers
fed by the input bus of the existing shared RemoteIO unit. Playback and capture
share one hardware unit. Capture data is converted to the requested mono/stereo
PCM16/PCM32/float format and rate, with packet ownership, positions, timestamps,
overflow/discontinuity reporting, event notifications and start/stop/reset.
No microphone device is advertised without host authorization. Bigscreen's
launch requests microphone permission and selects playAndRecord with mixing;
the legacy runtime category adapter preserves that input-capable category.

Only audio_null_ios.o in libntdll_unix.a is rebuilt. Every other archive member,
native archive and guest DLL is byte-verified against its retained parent.
Native capture compilation, production capture-ring ASan/UBSan tests and the
simulator audio-session policy probe pass. The physical capture probe remains
pending; it checks real input samples plus playback surviving repeated input
start/stop, and saves only level/position metrics, not recorded audio.


Candidate 72 exposed the microphone endpoint and obtained permission, but
AudioOutputUnitStart failed with OSStatus 'what' because WineProcessBridge's
modern setCategory:withOptions:error: call selected playback-only after host
preparation. Candidate 73 extends the host category adapter only while capture
is authorized: playback category requests retain playAndRecord, with the
caller's explicit options and real errors preserved. Capture-disabled modern
calls retain their existing behavior. The simulator policy probe passes both
paths. Production capture-control failure tests pass under ASan/UBSan, including
restoring playback after input-start failure, quiescing a retired client, and
keeping input stopped after a failed disable. Headset capture verification is
pending. Candidate-73 evidence is in `microphone73b/`.


Build 73 is installed. The fresh physical WASAPI probe passed: 172,320 mono
48kHz microphone frames, nonzero peak 0.09181528 and RMS 0.01231062, monotonic
positions/timestamps, and three capture start/stop/reset cycles with concurrent
playback's hardware clock still advancing. The fixture saves level/position
metrics only. Bigscreen has been relaunched for an in-game device/voice check;
end-to-end voice chat and the theater-room crash remain unresolved. Device
receipt: `microphone73b/device-probe1/receipt.json`.


## Frame queue starvation, candidate 74

Build 73's additional counters capture a frame-handoff stall: submitted frames
rise from 4680 to 5422, acquired frames remain at 1309, dropped frames rise from
3368 to 4110, and all three queue slots remain pending. The prior inference
that the game stopped producing frames was incomplete. The full queue discards
its oldest frame on every new submission, which can evict all frames before
their GPU-ready events signal when the GPU trails the CPU.

Candidate 74 coalesces a full queue only when another ready frame survives.
Otherwise it applies backpressure on the producer, releasing the bridge lock
while waiting. Display-side acquisition remains nonblocking. Pause, session
exit and changed target generations cancel pending submissions. The public
transport ABI, all runtime archives and all guest DLLs remain unchanged from
73; the app's native bridge target is rebuilt from the new source.

The old bridge fails the pending-queue regression. The patched production
bridge passes the simulator GPU test with commit-after-submit ordering and
held frame leases, plus pause/target-replacement/session-exit cancellation.
Source/artifact provenance explicitly records the superseding app bridge.
The latest guest exit still faults in BigSoup's video-packet reassembly at
RVA 0x23e701. This remains a separate unresolved crash, not a claimed queue fix.
Evidence: `.build-device/bigscreen-startup/queue74/` and `microphone73b/`.


Build 74 passed release, bundle, signature and app checks and installed on the
physical headset. The first remote launch failed with an unavailable XPC
remoteService; the sequential retry timed out. The subsequent file transfer
reported RemoteServiceDiscovery unavailable. The copied launcher log predates
the new installation and is not build-74 gameplay evidence. A manual launch
was requested; physical frame progress and in-game microphone selection remain
unverified. The standalone microphone result remains valid for the unchanged
audio implementation. See `queue74/device-validation.json`.

Static analysis narrows the video crash: the decoder dispatch searches the GPU
description for NVIDIA, AMD or Radeon, then sets its initialized flag even if
none matched. The AMD initializer allocates the packet-reassembly buffer at
context offset 0x30. The memcpy caller uses this buffer; Unity reports Apple M5
GPU and the physical crash has a null destination. Skipping initialization for
the Apple description is a likely cause, pending dynamic confirmation. No GPU
vendor spoof, fake decoder or game-binary patch was applied. Evidence and exact
RVAs: `queue74/video-initialization-analysis.json`.


Build 74 user validation: Settings opened without the previous lag and the
microphone endpoint appeared. Voice in a public room could not be tested
because joining again crashed. The new Unity log confirms the same BigSoup
memcpy RVA 0x23e701 and caller return RVA 0x970fe. This is not evidence of a
microphone regression or a new compositor fault. Fresh log: 
`public-room74/unity.txt`. End-to-end voice and incoming video remain open.


## Incoming H.264 video bridge, builds 75–76

The isolated decoder-dispatch probe executes the original BigSoup selector
instructions. Apple M5 sets initialized=1 with no initializer call and a null
packet buffer; NVIDIA/AMD/Radeon controls call their initializers. A separate
exact-revision, process-local change routes only the five incoming decoder /
display / cleanup selector reads to AMF. The original DLL bytes, actual GPU
description and outgoing encoder selection are preserved. BigSoup's AMF
factory is initialized independently of its outgoing encoder.

The source-owned AMF H.264 adapter uses a dedicated, versioned unix table and
VideoToolbox. It exposes real Y and UV GPU textures through a D3D11 device
decorator. BigSoup's separate decoder device is covered by its D3D11CreateDevice
import, with owned decorators released per stream. SPS/PPS and delayed pictures
return AMF_NEED_MORE_INPUT; BigSoup otherwise waits for output before submitting
the next packet. Native decoder IDs and queues are bounded, with explicit
flush/close and host session cleanup. Only virtual.o changes in retained native
archives; the microphone object, other archive members, graphics archives and
existing runtime DLLs are verified unchanged.

The launch installer checks the exact original BigSoup SHA-256 and packaged
file hashes, preserves the original as wvr_bigsoup_original.dll in the game
application directory, and rejects unknown revisions or conflicting files.
The AMF DLL also lives in that application directory for Windows loader lookup.
The Unity-facing forwarder remains in Bigscreen_Data/Plugins/x86_64. Original
DLL export forwarding, including data, is tested.

Host real-H.264 ASan/UBSan tests pass: decoded pixels, separate parameter packets,
resolution changes, buffer sizes, queue pressure, flush, close and session reset.
The installer passes original-preservation, repeat, conflicting-file, unknown
revision and tampered-package tests. A fresh physical probe on host build 75
with the build-76 guest artifacts passes AMF decode, both GPU plane readbacks,
all original exports, production factory/device/selector preparation, and
BigSoup's actual decoder initialization and shaders. The latter receives separate
SPS/PPS/SEI/picture packets and renders the expected Y=82 and UV=90/240 pixels
into its real A8 output textures. Evidence: video76/device-probe2/.

Build 76 passed release, signatures, bundle validation and required app checks.
Its headset installation and final gameplay verification are in progress.
Public-room stability and end-to-end voice remain unverified. This implements
shared-desktop H.264; the separate MFMediaEngine missing-class messages are not
claimed fixed.


Build 76 installed successfully. Fresh physical run
`e1e0538d-3b73-4a11-b4f1-48920c0a8ebc` passes the complete Windows/AMF/GPU
and original BigSoup decoder/shader tests on build 76 itself. The packaged
BigSoup forwarder and AMF DLL SHA-256 values match the tested probe files
exactly. Bigscreen is being relaunched for public-room verification. Final
physical evidence: `video76/device-probe3/receipt.json`.


The live build-76 game still exited at the original packet-copy RVA 0x23e701,
although its isolated decoder/shader tests passed. The adapter DLLs loaded and
the microphone remained authorized; the incoming selector setup had not taken
effect in the live startup path. Candidate 77 prepares in UnityPluginLoad and
BigSoupCreate before decoder workers start, with an unconditional visionOS
preparation call and a small plugin-local startup trace. The AMF decoder DLL
is byte-identical to the physically tested 76 artifact. Startup retest is
pending; public-room stability is still not claimed fixed.


Build 77 passed all build/bundle checks and installed. Its first automated
launch reached signed-in Steam checks, then remained in pre-launch service
preparation without starting the runtime. A clean retry timed out and the
subsequent file-service transfer failed with a closed socket. There is no
build-77 decoder trace yet because the captured session had not started the
game. A manual launch and a room-with-shared-video test were requested. Do not
claim public-room playback or voice chat fixed until that test completes.


## Build 77 user validation

The user answered “It does!” to the manual-launch test asking whether shared
video appears and the app stays open in a room sharing video. This confirms
shared-video playback and stability for that reported public-room session on
build 77. Settings responsiveness and the microphone endpoint were confirmed
earlier in build 74. End-to-end voice chat, longer sessions and repeated room
switching remain unverified. No further app restart, installation or diagnostic
launch was performed while the user was in the working session.


The user subsequently confirmed that other people can hear them through
Vision Pro Microphone. Build 77 therefore has user-validated shared-video
playback, stability in the tested public room, and end-to-end voice input.
Settings responsiveness and controller input were also confirmed earlier.
No active headset session was interrupted for this verification.


## Longer public-room sessions: reopened investigation

The user subsequently reported repeated unexpected exits from rooms while the
WineVision menu remains visible. Build 77's earlier video and voice validation
does not establish longer-session stability. Read-only evidence was collected
before relaunching: the two latest game logs end abruptly at approximately
8 GiB physical footprint (8184 and 8191 MiB), without a captured guest exception
stack. The latest Unity log shows room/asset activity before ending. The
video adapter trace confirms successful early preparation (status 7). The
systemCrashLogs service returned no new WineVision IPS or JetsamEvent, so a
specific system termination reason has not been verified.

An isolated physical probe using build 77's exact AMF/forwarder DLLs, a
1920x1088 H.264 fixture, and the original BigSoup decoder/shaders completed
1500 repeated frames. Its footprint peaked around 1612 MiB and fell to
1310 MiB after completion. This does not reproduce sustained memory growth
in that isolated path and does not rule out room/display integration or
other game allocations. A new gameplay run has performance diagnostics
enabled to separate CPU footprint growth from Metal allocation growth.
Evidence is under `.build-device/bigscreen-startup/room-exits77/`.

Build 78 reproduced the unexpected exit with performance diagnostics enabled.
The final sample at 11:04:13 on November 3 recorded 8,587,458,408 bytes of
process footprint and 2,476,184 bytes of headroom under the 8 GiB process
budget. Metal allocations hovered around 1.6–1.7 GiB as the footprint rose
from about 6.2 to 8 GiB. The runtime's guest address band showed roughly
3.4 GiB of dirty or swapped pages near the exit, while the native malloc zone
remained at about 121 MiB in use. The last GPU sample recorded all submitted
command buffers completed with zero failures. No fresh Jetsam report was
available. The evidence points to process memory exhaustion and narrows the
next investigation to guest allocations. The allocation owner remains
unknown. Captures are in room-exits77/build78-exit-*.txt.

Build 80 added a low-memory warning during active Wine sessions. It appears
as a banner in the game window and is spoken during full immersion. The
warning starts at 512 MiB of process headroom and rearms after recovery to
1 GiB. In the build-78 trace that threshold was first crossed about two
minutes before the final sample. Both release builds and the 16 core tests
passed. The headset warning still needs a live check.

Diagnostic build 81 replaces only virtual.o in a separate copy of the
Wine native archive. With WVR_GUEST_MEMORY_OWNERS=1 it samples guest VM
regions against live Wine views and groups dirty and swapped bytes by the
view creator's PEB. Regions that cross view boundaries or cannot be looked
up without waiting are reported separately. The creator describes the
reservation, so a shared view or a reservation populated later is not proof
of which module owns its contents. The runtime patch and build logs are in
room-exits77/ownership. The Bigscreen video adapter DLLs match build 77
byte for byte. Build 81 installed successfully. Remote launch timed out
twice, so ownership data and in-room playback on this build are pending.

## Build 81 allocation capture and process-budget correction

The November 5 build-81 exit occurred with no shared video playing. The
user confirmed hearing the warning. The ownership census identified the
main Bigscreen.exe PEB as the creator of most growing private allocations,
reaching roughly 2.5 GiB of dirty or swapped private pages in the sampled
guest band. This includes compatibility libraries inside the same Windows
process and does not establish the responsible allocator.

Wine's SystemPerformanceInformation used device-wide free RAM and commit
capacity while SystemBasicInformation already capped total RAM to the app
limit. A physical Windows probe on 81 reported 16,501,837,824 bytes of
commit capacity against an 8 GiB process budget. Patch 0028 caps the physical
and commit totals consistently and limits available memory to current
os_proc_available_memory(). Zero headroom is preserved. An unlimited-memory
sentinel is rejected. Desktop Wine/macOS builds retain their existing path.

The production calculation regression passes with ASan/UBSan and fails
against the original host-wide calculation. Build 82 passed the same
Windows API probe on the headset and a controlled 4 GiB allocation run.
The corrected commit limit was 8,589,934,592 bytes. Available memory fell
to 3,515,752,448 bytes after the allocations as app headroom became limiting.
This verifies API accounting, while the gameplay exit remains unresolved.

Build 83 carries the correction, existing warning, and optional finer
ownership snapshots. Only system.o and the diagnostic virtual.o differ in
the native archive. Shared-video adapter DLLs match the working build 77
bytes. The launch was successful and the first traced game reached about
6.5 GiB of footprint. Logs then show a manual restart at 11:43, after which
one-time diagnostic flags no longer apply. The user was asked whether the
first session crashed or was closed deliberately and whether the current
room remains active. Build-83 gameplay stability is pending.

Saved guest PCs in the allocation metadata resolve to managed exception
landing pads, so they must not be treated as allocation backtraces. The
next allocator-level distinction, if growth persists, is IL2CPP managed
heap use versus native allocations. The exact GameAssembly.dll export
accessors are retained locally for that investigation.

## Builds 84–85: managed heap measurement and cooperative collection

The user clarified that an earlier build-83 test was closed deliberately,
while the latest run did crash after the warning. The reporting correction
alone therefore does not resolve the gameplay exit.

Build 84 adds a read-only sampler of the exact GameAssembly export accessors.
It checks the mapped PE and accessor instructions, reads metadata through
Mach's checked read API, and fails closed on inaccessible or inconsistent
counters. A live session grew from roughly 1.1 GiB to 1.6 GiB of managed use.
The user reported that room occupants and incoming voice froze while local
movement and menus continued; returning home remained at "hold on". Unity's
log includes HTTP 500 responses and TLS errors, but these do not establish
the cause of the room stall. Captures are retained in `memory84` under the
existing local Bigscreen evidence directory.

Build 85 retains the corrected process budget, native sampler, low-memory
warning and exact working build-77 AMF decoder bytes. The BigSoup proxy now
samples the exported IL2CPP counters after the original pending-callback
function returns. It requests a bounded-frequency collection only from an
already attached thread while game-controlled GC is enabled. It has an
environment opt-out and stops repeating collections that make no progress.
The first physical collection reduced managed use from 517 MiB to 97 MiB
in 47 ms. This demonstrates reclaimable garbage, but does not establish
sustained footprint stability or explain the separate room-connection stall.

Build 85's real H.264/AMF/original-BigSoup shader and GPU-readback probe passed
on the headset. Packaging (24), core (16), and app contract (6) tests passed,
alongside ASan/UBSan checks for the pressure collector and process-budget
calculation. Strict signatures and the production bundle validator passed.
Gameplay validation is in progress; `memory85/receipt.json` records the
diagnostic native archive replacements and exact guest/package hashes.

### Build 85 extended room test and remaining performance issue

The user reports that the memory issue appears resolved, but a crowded room
has severe lag. The extended adapter trace contains repeated successful
collections, generally reducing roughly 512–555 MiB of managed use to
110–139 MiB in 25–58 ms. The managed heap reserve reached about 612 MiB,
instead of the earlier 1.6 GiB growth. This is evidence of sustained reuse
in this session, rather than a guarantee for every room or game.

The retained 13:06–13:11 launcher window confirms approximately 2–14 fresh
frames per second during the slow period, then 40–43 FPS near its end.
The guest GPU failure counter remains unchanged throughout that window,
the compositor queue is usually empty, and presentation continues near
60 submissions per second. Process footprint remains below the app limit
with roughly 1.1–1.5 GiB of headroom. Thermal state is serious in both the
slow and recovered intervals. These observations do not identify a single
CPU, synchronization, scene, or thermal cause; the infrequent collections
alone cannot explain the sustained slowdown.

The app is no longer running by the time the process inventory is taken;
the log ends with immersive-space closure and `stop()`. No restart or new
performance build was performed. A live crowded-room CPU profile is the
next measurement, with shared-video activity recorded for comparison.
The user subsequently confirms that no video was playing during the
crowded-room slowdown. Active incoming-video decoding is therefore not
required to reproduce it; avatar/scene work, synchronization and thermal
effects still need a live profile rather than an assumed attribution.
Evidence: `memory85/launcher-full-room.txt`, `adapter-full-room.txt`, and
`full-room-performance.json` under the local Bigscreen evidence directory.
