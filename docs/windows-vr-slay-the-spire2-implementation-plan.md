# Slay the Spire 2 graphics implementation plan

Updated October 29, 2026. Steam app: 2868840. Target: the user's M5 Vision Pro,
desktop presentation. **Build 18 is installed and passes the user’s first-combat
and card-play test.** The user also confirmed steady menu colors in build 17;
sixteen paired GPU frames verified that the presentation output matches its
correctly rendered input after the display-query fix.

The completed implementation combines scoped ANGLE/D3D11 launching and managed
runtime repairs, safe BC7 texture creation, deterministic mobile display-query
outputs, and a game-specific 896 MiB executable arena. The latter resolves the
first-combat loading failure reproduced with the 640 MiB arena. Pool bounds,
explicit override precedence and other games' defaults are preserved. Host
policy, regression, packaging and signing checks pass. Acceptance covers the
menu, first combat and card play; later acts and an entire run remain untested.

See the [implementation evidence](windows-vr-slay-the-spire2.md#build-18-scoped-executable-arena-capacity).

## Diagnosis and chosen approach

The attached image shows Godot's “Unable to initialize video driver” dialog,
reporting a Direct3D 12 initialization failure. The desktop/error dialog is
visible, but this does not establish successful game rendering.

The existing source and earlier device experiments explain why another retry
of the normal renderer is unlikely to help:

- `third-party/dxmt-d3d12-experimental/src/d3d12/d3d12_device.cpp` reports
  Shader Model 5.1. `d3d12_pipeline_graphics.cpp` explicitly rejects DXIL.
  Godot 4.6's D3D12 source checks for at least Shader Model 6.0 and uses DXIL.
  Establish the installed game's exact engine version in the first phase;
  the cited engine source is corroborating evidence, not an identification of
  the installed binary.
- The earlier default-renderer trace contains an unsupported
  `D3D12GetInterface` query. Its causal role is unconfirmed; implementing that
  interface alone would still leave the shader incompatibility.
- Earlier ANGLE trials loaded the D3D11 path and created a 1912×1046 client
  window. They did not establish correct rendering. Their DLL/config files
  were subsequently removed, explaining why the installed build still allows
  the normal renderer to encounter the original error.
- Those trials also exposed a .NET 9.0.7 virtual-address reservation failure.
  A process-only 8 GiB reservation experiment advanced to a CoreCLR
  write-barrier assertion. Disabling W^X then produced an access violation.
  The underlying runtime defect remains unidentified.

Recommended initial route:

`Godot Compatibility → ANGLE → D3D11 → DXMT → Metal → desktop surface`

This route has already advanced beyond the original graphics boundary. It is
still experimental: Compatibility may omit features the game needs, and the
.NET failure must be fixed before claiming a playable result. Full DXIL/SM6
support is a separate, substantially larger backend project if this route
cannot render the game's required content.

## 1. Establish small, reproducible failures

Record the installed game build, engine and CoreCLR versions, app/runtime build
IDs, renderer selection, and hashes of the graphics DLLs actually loaded.
Keep each run's output separate and retain the first failure before teardown.

Add two standalone fixtures under `windows-vr-native/Tests/`:

1. A minimal exported Godot scene matching the game's engine version, first
   without managed code. Exercise ANGLE context creation, textured and blended
   drawing, resizing, and repeated presentation. Add representative game
   shader features after the basic scene passes.
2. A self-contained .NET 9.0.7 x64 program which initializes CoreCLR, allocates
   and updates references across forced collections, and executes generated
   code. Exercise its normal executable-memory path under Wine/FEX. Compare
   the default GC reservation with the previous bounded process-only trial.

Record HRESULTs, shader stages and bounded shader/pipeline inputs for graphics;
record reserve/map/protect/copy/flush operations and owning pseudo-process for
the managed fixture. A controlled native Windows run provides a reference for
the fixtures where available. Neither fixture should require launching Steam.

Exit condition: independent reproductions of the graphics behavior and managed
failure, or evidence that the smaller fixtures do not reproduce them and must
be extended. Do not select a runtime patch from the assertion text alone.

## 2. Repair the managed runtime boundary

Trace the failed write-barrier patch from CoreCLR's executable-memory allocator
through Wine virtual memory and FEX's aliases. Compare expected instruction
bytes with the bytes visible at the guest executable and writable addresses,
before and after copying and patching the barrier. Determine whether the fault
is relocation, copying, address translation, permissions, alias ownership, or
stale translated code.

Implement the correction in the component demonstrated to be wrong. Carry
Wine/FEX changes as source patches alongside
`windows-runtime-plugin/patches/0009-wine-process-jit-aliases.patch` and the
existing JIT-pool arbitration patch. Preserve per-process ownership, allocation
failure behavior, teardown, and instruction-cache/translation invalidation.
Rebuild through the source preparation and runtime build pipeline; avoid
address-specific patches to a packaged binary.

Keep CoreCLR's write-barrier assertion and executable-memory protections.
Evaluate any bounded GC reservation separately, using successful allocation
and collection evidence; do not promote the earlier trial values to defaults
merely because they advanced startup. Preserve `sts2.runtimeconfig.json`.

Exit condition: repeated startup and forced collections pass with valid object
references, generated-code patches execute their new values, and concurrent
pseudo-processes and restart/teardown do not share or retain stale aliases.

## 3. Validate and fix ANGLE drawing

Use a pinned, reproducible Windows x64 ANGLE build with the D3D11 renderer,
recorded DLL hashes, dependency closure, and required notices. The prior Chrome
for Testing DLLs are experiment inputs, not the production packaging decision.
Capture the selected EGL backend so a run cannot silently use D3D12 or software
rendering and appear to validate the intended path.

Investigate `Geometry shader cannot be independently converted` by recording
the API call, HRESULT, pipeline variant, bound stages, and final draw result.
DXMT already has combined geometry-pipeline compilation in
`src/d3d11/d3d11_pipeline_gs.cpp` and `d3d11_shader.cpp`; the independent-converter
warning does not establish whether that later path succeeds. Correct the
actual pipeline selection/conversion defect if the fixture demonstrates one.
Implement required semantics rather than dropping a stage or hiding an error.
Persist changes through the DXMT patch/preparation/staging system, not only in
the generated third-party checkout.

Exit condition: actual pixel readback matches known fixture results for the
required drawing paths; repeated present/resize/stop cycles complete without
pipeline failures, GPU faults, stale surfaces, or synchronization stalls.

## 4. Deliver a persistent, scoped launch profile

Add a versioned compatibility profile for app 2868840. Integrate selection and
preflight with `LauncherModel.swift` and keep the existing measured code-cache
workaround in `WindowsVRTranslationEnvironment.swift`, including explicit
override precedence. Keep the current desktop/D3D11 transport declaration;
Godot's rendering driver is a separate selection.

Use `MadeiraDock.extraLaunchArguments` and the existing bounded
`MADEIRA_STEAM_HOST_EXTRA_ARGS` forwarding to pass:

```text
--rendering-method gl_compatibility --rendering-driver opengl3_angle
```

Verify argument handling against the installed engine and the actual Steam
child process, including launch retries. Arguments on `dockhost.exe` alone do
not establish that the game received them. Define and test precedence for
explicit user renderer options; never append contradictory renderer flags.

Extend `stage_resources.py` and packaging tests to stage the ANGLE package and
its provenance. Add an app-owned deployment helper for the side-by-side DLLs
Godot loads next to its executable. Check architecture and hashes before
launch, deploy transactionally, preserve conflicting user files, and maintain
an ownership ledger for recovery and removal. Prefer verified command-line
renderer selection; use `override.cfg` only if required by this engine and with
equivalent preservation and restoration. Game updates must trigger revalidation.

Missing or incompatible assets should produce an actionable launch failure.
Promote the profile to the game's default only after the runtime, rendering,
and end-to-end checks pass. Other games retain their existing launch behavior.

## 5. Expose useful readiness and failure states

Extend `SessionDiagnostics.swift` and the status handling in
`LauncherModel.swift` to record requested and observed renderer, profile revision,
graphics package hashes, managed startup errors, and first presentation evidence.
Keep logs bounded and exclude credentials and unrelated argument contents.

Distinguish Wine process activity, graphics initialization, frame presentation,
and observed game readiness. A window, desktop capture, successful `Present`,
or changing frame counter alone cannot establish playable content: an error
dialog also renders. Report known renderer or managed failures explicitly;
retain unknown readiness when no game-specific evidence exists. Avoid reading
dialog pixels as the sole failure detector.

## 6. Regression and physical-device acceptance

Run focused policy/argument tests for target-game scoping, override precedence,
retry forwarding, game switching, and cleanup. Test missing/wrong-architecture
ANGLE files, deployment conflicts, interrupted deployment, and game updates.
Run the graphics and managed fixtures, packaging/dependency checks, source
receipt checks, app build, and signature verification.

Then validate on the physical M5 headset:

- Three cold launches reach the menu and a playable encounter without a video
  driver dialog or CoreCLR termination.
- Cards, text, effects, transparency, and colors render correctly; pointer and
  keyboard input work on the desktop surface, with sustained audio.
- At least ten minutes of play, including scene changes and GC activity,
  produce no GPU faults, repeated shader failures, or unbounded memory growth.
- Stop, relaunch, resize, and switching to a different game work; the profile
  does not leak renderer arguments, GC settings, or file changes to that game.

Record build IDs, observed renderer, logs, and visual verification. Reaching a
new error is diagnostic progress, not completion. Make no FPS or broad game
compatibility promise until measured.

## Evidence and primary references

- Existing device findings: [diagnosis](windows-vr-slay-the-spire2.md).
- Local normal-renderer evidence: `.build-device/madeira-godot-driver.txt`,
  line 11865 (`D3D12GetInterface`).
- Local ANGLE/GC evidence: `.build-device/madeira-angle-after-startup.txt`,
  lines 13239, 13311, 14014; `.build-device/madeira-angle-dotnet.txt`,
  lines 13878, 13907, 13910. These are earlier trials, not new logs from the
  attached screenshot's session.
- [Godot ANGLE support and side-by-side DLL loading](https://docs.godotengine.org/en/4.4/contributing/development/compiling/compiling_for_windows.html#compiling-with-angle-support).
- [Godot 4.6 D3D12 implementation and shader-model checks](https://github.com/godotengine/godot/blob/4.6/drivers/d3d12/rendering_device_driver_d3d12.cpp).
- [Godot Windows renderer selection and error dialog](https://github.com/godotengine/godot/blob/4.6/platform/windows/display_server_windows.cpp).
- [.NET 9.0.7 write-barrier patch assertions](https://github.com/dotnet/runtime/blob/v9.0.7/src/coreclr/vm/amd64/jitinterfaceamd64.cpp).

The original planning pass changed only this document. The subsequent authorized
implementation added diagnostic fixtures and a runtime source patch, built and
installed diagnostic build 4, and reproduced the baseline defect on-device.
The issue is not marked fixed; post-fix execution and remaining phases are open.
