# Balatro desktop startup — November 5, 2026

Current device build: **90**. Build 88 established working Balatro desktop
startup, build 89 added audio recovery after Discord screenshares, and build
90 corrected pinch selection and dragging. The user confirmed all three
results. See `windows-vr-audio-recovery.md` and `windows-vr-desktop-pinch.md`
for the later validations.

Build 88 launches the desktop client without temporary memory overrides.
The matching-settings trial survived at least 106 seconds with no pool
exhaustion or unhandled page fault. The user subsequently confirmed that
build 88 reaches the animated menu and everything works, including controls.

The initial Steam launch (app 2379780, option 0) reaches Balatro, then its
stock `lua51.dll` (LuaJIT 2.0.5) requests a 128 KiB reservation below 2 GiB.
The device cannot map that range inside the host's page zero. The failed
allocation returns `STATUS_NO_MEMORY`; Lua subsequently reads address 8 and
terminates with `0xc0000005` at `lua51.dll+0x55ec0`.

A Windows x64 LuaJIT 2.1 GC64 build passes this point. Its exported Lua API
covers every Lua import in the installed `Balatro.exe` and `love.dll`.
The interpreter is used to avoid nested guest JIT allocations.

The next failure is `Failed to initialize filesystem: no error`. PhysFS
calls `GetUserProfileDirectoryW`, which fails with `ERROR_NONE_MAPPED`.
The prefix has a configured computer name, but lacks the active computer
name normally created by wineboot. `LookupAccountSidW` needs that name to
resolve the local user's token. Adding the active name from the configured
name makes the profile query return `C:\users\mobile`; PhysFS then initializes.

`BalatroCompatibility` applies these repairs before Wine starts, scoped to
this Steam app. It preserves the stock Lua DLL in
`lua51.dll.winevision-original`, rejects an unknown modified runtime, checks
the generated compatibility DLL hash, and installs the existing pinned ANGLE
renderer alongside the game. Existing unknown renderer DLLs are preserved.
The game receives `LOVE_GRAPHICS_USE_OPENGLES=1` and
`SDL_OPENGL_ES_DRIVER=1` unless explicitly overridden.

Build the runtime before building the app:

```sh
AVPPLAY_LLVM_MINGW_ROOT=/absolute/path/to/llvm-mingw \
  bash windows-vr-tools/build_balatro_luajit.sh
```

The script builds the pinned upstream revision and stages the DLL, its
copyright notice, and a receipt under the already bundled
`Resources/GameCompatibility/Balatro/` folder. Generated binaries are ignored
by Git. The verified DLL SHA-256 is
`a77addc0c78fb0665bae6b7894379999dd9458633a990326982cdfcadf74d086`.

Earlier physical trials passed both original startup failures and created a
1920×1080 game window with working audio, but the loading bar remained after
music started. A separate clean-runtime trial also recorded a Steam client
fatal allocation with a negative size. These intermediate trials did not
establish sustained rendering; builds 87–88 resolved the remaining failures.

The build-86 frozen capture shows 32,757 `D3DCompile2` calls. The main game
thread uses approximately 99% of one CPU and is sampled inside the Wine
shader compiler in `wined3d.dll`. Three compile flag combinations repeat
over 10,000 times each. This identifies shader compilation as the immediate
stall in that trial.

The following trial staged the user's already installed Microsoft
`d3dcompiler_47.dll`, from Bigscreen's Chromium plugin, beside Balatro. Its
SHA-256 is
`7353f25dc5cf84d09894e3e0461cef0e56799adbc617fce37620ca67240b547d`.
Wine's D3DCompiler DLL has the `prefer-native` flag, so an app-local native
compiler takes precedence. The plugin's graphics/XInput DLL overrides are
preserved. This proprietary dependency is reused on the same device and is
not packaged in WineVision or committed to the repository.

Build 87 verifies an existing copy or obtains this exact compiler from an
installed Bigscreen in the same Steam library. An unknown compiler file is
preserved. If neither copy exists, launch reports the missing dependency.

Build 87 was signed and installed. It packages the clean Lua runtime and
ordinary-launch preparation, including the compiler check. Its
signed app build and production bundle validation pass, as does the Swift
contract test for registry repair, idempotence, control-set selection, and
scoped environment defaults. Temporary Lua API/error/file tracing is excluded
from the packaged runtime. Evidence is retained in
`.build-device/balatro-startup/`.

The first Microsoft compiler trial was blocked by a StikDebug tunnel
disconnection. The helper recorded a tunnel timeout and remote pairing
connection resets; the launcher timed out waiting for debugger attachment
before starting Wine. The user restored connectivity and retried, producing
the build-87 result below.

## Build 87 retry: Steam API initialization exhausts the JIT pool

After restoring the tunnel, the user's 16:22 retry loaded the native Microsoft
compiler and advanced to `luasteam.dll` initialization. It then failed while
loading additional Steam/security libraries: DLL images used `0xdfe4000`
bytes (about 224 MiB) from the head, while cache-launcher reservations used
`0x1a010000` bytes (about 416 MiB) from the tail of the 640 MiB pool. Even a
592 KiB module no longer fit. Repeated failed image mappings and protection
changes culminated in a guest access violation. No new host crash or jetsam
report matched this run.

Balatro now joins the existing observed code-space exceptions: persistent
translation caching defaults off, and the JIT pool defaults to 896 MiB.
Explicit manifest/process overrides remain authoritative. This does not add
the separate L2-cache or host-arena overrides used by Bigscreen/Risk of Rain 2.
The translation-environment contract covers Balatro, saved environment values,
explicit overrides, and exclusion of unrelated games. Build 88 passes that
contract, its Release app build, and strict code-signature verification.

A build-87 process trial with the same two settings remained active for at
least 106 seconds. Its capture contains no JIT-pool exhaustion or unhandled
page fault, and samples the game thread executing in `love.dll` with
`libGLESv2.dll` on its stack. The user subsequently confirmed the animated menu and working controls on
build 88.
Evidence is under `.build-device/balatro-startup/build87-retry/`; the signed
build-88 artifact and validation record are under
`.build-device/balatro-startup/build88/`.
Build 88 is installed and its ordinary launch reaches the 1920×1080 desktop
client without process overrides for either memory setting.

The user confirmed the final build-88 headset result: “Yes! everything works
now.” Balatro desktop startup, menu animation, and controls are validated by
that report.
