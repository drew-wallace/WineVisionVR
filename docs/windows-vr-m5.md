# M5 rendering and validation

The M5 changes preserve the M2 rendering path and prioritize new game frames and
pacing before higher resolution. They do not establish a game FPS improvement.

## Delivered behavior

- Both XcodeGen configurations use the same 1888×1792 logical eye raster. This
  is a comparison baseline, not a claim about physical panel resolution.
- The launcher, render policy and session journal use a Metal capability snapshot
  (GPU family, ray tracing, rate maps, physical memory and recommended GPU working
  set). Apple GPU family 10 or later selects M5-capable options; model-name strings
  do not enable features. Capability is distinct from validation.
- **Automatic (baseline)** retains those dimensions. **M5 quality (experimental)**
  uses at least 2048×1920 on Apple10-capable GPUs, otherwise retains the baseline.
  This adds about 16% pixels at the standard baseline. Save the game profile to
  retain the preset. Legacy profiles decode with automatic behavior. Existing
  render scales and explicit launch-environment overrides remain authoritative.
  The launcher freezes the raster before opening the immersive space; guest
  swapchains are not resized during play.
- Synthesis engagement/disengagement uses 85/90 and 88/90 of the measured display
  rate, preserving the previous behavior at 90 Hz. Half-rate pacing uses the same
  ratios at 96, 100 and 120 Hz. Cadence changes, missed display ticks, tracking loss,
  pauses and stalled source frames discard adaptive history. Display timestamps
  come from CompositorServices; the existing native measured-period/OpenXR path
  remains intact. No public API is used to force a 120 Hz mode.
- Presentation logging separates fresh transfers, scene-motion extrapolation and
  reused/reprojected presentations. Native mode-4 counters no longer label fresh
  reconstructions as generated display jobs. The additive
  `wvr_synthesis_last_display_kind_v1` query identifies the last encoded output
  without changing any existing transport structures.
- Source and prebuilt targets include the same student weights, FSR shaders and
  MetalFX/CoreML/CoreVideo dependencies. MetalFX temporal functions are stubs on
  visionOS because the SDK marks the API unavailable. Header presence is not used
  as an availability check.
- Shared FSR shader build fixes use explicit vector conversions, keep SPD mip
  0–4 write-only (its cross-workgroup tail reads only mip 5), and use MSL 4 for
  device-scope fences. Shader language selection does not enable M5-only kernels
  on M2. Existing FSR opt-in behavior is unchanged.

## Experimental M5 tensor convolution

`WVR_NEURAL_M5_TENSOR=1` in the **app process launch environment**, together with
Apple10 capability, opts into a separate MSL 4 / Metal Performance Primitives
matrix-multiplication implementation of the existing FP16 3×3 convolutions.
Use Xcode's scheme environment, not the Windows game's environment: reconstruction
is initialized before Wine starts. `WVR_NEURAL_NAIVE_CONV=1` still takes precedence.

It consumes the same OIHW student weights and NHWC feature maps. Input gathering
preserves zero padding and input ReLU; FP32 matrix sums feed the existing bias,
residual, output ReLU and FP16 output semantics. The implementation reuses bounded
scratch buffers with ordered GPU barriers. Scratch is capped at 64 MiB and checked
against the device's recommended working set; allocation/compile failures or
unsupported GPUs use the existing tiled/naive convolution. A failed GPU command
disables the experimental backend for the remaining context lifetime. `tensorConvJobs`,
`tensorFallbacks`, and `tensorScratchBytes` appear in the native synthesis report.

This path is **off by default on all devices**. Host numerical checks do not
establish that input gathering plus tensor work beats the tiled kernels on M5.
The gate must stay off until identical-weight image comparisons, stereo quality,
end-to-end latency and sustained game pacing pass on the headset. MetalFX temporal
upscaling, Windows ray tracing and mesh shaders are not enabled by this change.

## Collecting a comparable game baseline

1. Use an optimized Release app built with matching Wine/FEX/DXMT artifacts. Full
   bundle assembly/signing still requires the runtime setup in the main README.
   A source-built Release app is now signed and installed on the M5 headset; see
   [the device-build handoff](windows-vr-device-build.md) for the saved artifact.
2. Enable **Performance diagnostics (restart app)** and restart. This collects
   bounded five-second summaries and GPU timings without enabling the heavy bridge
   trace or frame capture. Both build configurations disable `WVRDiagnostics` by
   default; that Info.plist flag can still enable the full diagnostic mode.
3. Record the exact title (Moss and Moss: Book II are separate baselines), scene,
   settings, app/runtime build, power conditions and starting thermal state. Use
   Automatic, 100% spatial and internal scales, and unchanged game settings.
4. Run synthesis **Off**, then mode **4**, with separate app launches and journals.
   Separate the first cold launch from subsequent warm-cache launches. Keep the
   existing ARM64EC and FEX cache defaults; do not tune them between comparisons.
5. Replay the same scene and the formerly problematic page transition. Capture at
   least 30 minutes of sustained play on M5 and repeat the fallback regression on
   M2. Repeat with the tensor opt-in only after the baseline is stable; compare the
   quality preset separately after performance work.
6. Export the session journal and launcher logs, including rotated logs. Metadata
   includes hardware, requested eye raster, preset and synthesis mode. Reports
   include fresh-frame interval p50/p95/p99, display cadence, generated/reused
   submission rates (not confirmed physical scanout), color-snapshot traffic, GPU execution/queue delays, thermal state,
   cumulative whole-process CPU seconds, process physical footprint, current GPU
   allocations, recommended GPU budget and available process memory. CPU deltas
   include every thread; use Instruments samples to attribute translator/query
   work rather than labeling the aggregate as guest simulation CPU. GPU memory is
   part of unified memory and must not be added to physical footprint. Available
   process memory is reported as -1 where unsupported (macOS host probes).

Retain owned frame snapshots and exact GPU-event progress. Fresh transfers measure
arrival rate, not simulation time; generated/reprojected output is never counted
as real game FPS. The 90-real-FPS goal remains aspirational, with an 11.11 ms budget.

## Local verification

Run `python3 windows-vr-tools/test_m5_optimizations.py`. Results and individual logs
are written under `.build-m5-optimizations/`. This checks core policies and legacy
profile decoding, 90/96/100/120 Hz cadence transitions and stalls, the entire Swift
app's visionOS type checking, native bridge syntax, tensor and FSR visionOS shader
compilation, host tensor numerical comparisons, packaging, frame transfer,
presentation, guest foveation, synthesis, and build-configuration parity.

Host tensor tests ran on an M4 Pro. Eight convolution cases covering stride 1/2,
padding, irregular dimensions, 3/40 input channels, 5/32 output channels, ReLU and
residuals matched an FP32 CPU reference with maximum absolute error 0.00006104.
Default-off selection, pre-Apple10 fallback, scratch reuse and the allocation bound
also pass. These are math checks, not evidence of M5 neural-accelerator speed.

The existing reconstruction GPU probe also passes plain/sRGB and array variants.
Its subsequent guest depth tests and full FEX cache-parser tests were not run in
the initial optimization pass. Their dependency sources are now available after
the complete runtime build; those additional test results remain unverified. The
unchanged translation-environment regression confirms persistent-cache defaults
and explicit overrides.

The source-built Release app was installed on the physical M5 headset on October
27, 2026. No game was launched. Cold/warm game FPS, latency, 30-minute thermal
behavior and physical M2 fallback remain acceptance gates.
