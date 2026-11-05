Bigscreen incoming video adapter
===============================

BigSoup revision SHA-256 `6c88f56e09b810e848fcea0cb2c97ded46c08a94d8e2cd29b2146f0fab64ab04`
sets its initialized flag for an unknown GPU description without allocating its
video-packet buffer. An isolated headset probe executes the original dispatch
instructions and reproduces that state for Apple M5, alongside recognized GPU
controls. Incoming video then faults at memcpy RVA `0x23e701`.

The adapter forwards the original plugin's exports and supplies the AMF H.264
decoder interface using VideoToolbox. Five exact-revision, process-local
selector reads route incoming decode and display to that interface. The original
file, real GPU description and outgoing encoder routing are preserved. The
plugin receives a D3D11 device decorator. Two ordinary GPU textures carry NV12's Y and UV planes; the
decorator creates real plane SRVs without advertising general DXMT NV12 support.
The plugin's D3D11CreateDevice import also returns an owned decorator for each
decoder device; these devices are released with the stream. Parameter-only and
delayed-picture submissions return AMF_NEED_MORE_INPUT, so BigSoup can submit
the next packet instead of waiting for a picture that is not ready.
Other codecs, AMF encoders and unsupported APIs return explicit failures.

`WindowsVRVideoDecoder.h` defines a separate, versioned 64-bit unix ABI. The
loader binds it only for the adapter's `amfrt64.dll`; existing unix table indices
are unchanged. Decoder IDs have bounded lifetime and queues. Annex-B parsing,
parameter-set updates, native decode, plane copies, flush and close are tested
with real H.264 pixels by `windows-vr-tools/test_video_decoder.sh`. The Windows
probe additionally exercises AMF, resolves every plugin export, and executes
BigSoup's actual decoder initialization, packet submission, shaders and GPU
readback in an isolated process without a game or network connection.

The launch installer verifies the packaged files and the exact original plugin,
saves it unchanged as `wvr_bigsoup_original.dll`, and atomically installs the
forwarder and decoder. Conflicting files and unknown game revisions are preserved.
The saved original and AMF adapter live in the game's application directory,
which is searched by Windows forwarded-export and dynamic-library resolution.
In-game playback and room switching must still be verified on the headset.

The memory-pressure candidate also wraps `BigSoupExecutePendingCallbacks`.
After the original function releases its callback mutex, it samples Unity's
exported IL2CPP heap counters on the existing attached thread. At 2 GiB or less
of reported headroom and at least 512 MiB of managed objects, it requests a
collection through `il2cpp_gc_collect`. It respects game-disabled collection,
waits at least 30 seconds between collections, and stops after two attempts
that each reclaim less than 32 MiB until headroom recovers above 3 GiB.
`WVR_BIGSCREEN_MEMORY_PRESSURE=0` disables this intervention for comparisons.
The existing adapter log records before/after counters and collection time.
`python3 windows-vr-tools/test_bigscreen_memory_pressure.py` exercises the real
class with controlled OS and Unity exports under ASan/UBSan. Sustained gameplay
and room connectivity remain separate headset checks.

Header sources and licenses:

* AMD AMF public headers, MIT, revision `57ee0cfb0e1a08d9041f77435653794c1b012be0`:
  https://github.com/GPUOpen-LibrariesAndSDKs/AMF
  Copyright and license notices remain in each header.
* Unity native interfaces, MIT, revision `522254181faf188efa8b50c3e3bf6fce720b26e4`:
  https://github.com/Unity-Technologies/NativeRenderingPlugin
  License is in `third-party/unity/LICENSE`.
