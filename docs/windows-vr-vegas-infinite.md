# Vegas Infinite startup

## November 5, 2026: shared VR and desktop failure

The physical M5 Vision Pro's retained logs identify the same startup failure
for Steam app 886250 in both modes. The VR attempt uses launch option 1 and
starts `PokerStarsVR.exe` without arguments. The desktop attempt uses option 9
and passes `SteamNonVr`. Both create a fatal-error dialog containing
`Failed to load il2cpp`. The user sees only black in the immersive view.

The immediate blocker is executable JIT pool exhaustion. The 640 MiB pool has
416.0625 MiB reserved for translator code and 223.828125 MiB occupied by loaded
images when `GameAssembly.dll` requests another 198.46875 MiB. Its executable
mapping is refused repeatedly. Dependencies including `baselib.dll` also fail
to acquire pool mappings, followed by protection faults and the fatal dialog.
Both attempts contain 29 `EXHAUSTED` messages. Their Unity `Player.log` files
are empty; this failure precedes normal Unity startup logging.

Evidence is retained in `.build-device/vegas-infinite-diagnosis/initial/`:

- `madeira-log.previous-1.txt`: VR spawn at line 8154, GameAssembly pool
  refusal at line 10538, and IL2CPP dialog text at line 11569.
- `madeira-log.txt`: desktop spawn at line 8069, GameAssembly pool refusal
  at line 10439, and IL2CPP dialog text at line 11481.
- `launcher-log.txt`: identifies the remembered VR and desktop launch options.
- `../diagnosis.json`: structured evidence and pool arithmetic.

## Compatibility change

`WindowsVRTranslationEnvironment.compatibilityEnvironment` now includes
886250 among the games requiring additional executable code space. Both launch
modes receive `FEX_ENABLECODECACHINGWIP=0` and `WVR_JIT_POOL_MIB=896` through
the existing policy. Explicit profile and process overrides retain precedence.
The first device retry establishes a second memory failure: Vegas also needs
the existing L1-only translator lookup layout and larger host arena. Its scoped
policy therefore additionally sets `FEX_DISABLEL2CACHE=1` and
`WVR_FEX_ARENA_GIB=32`, preserving explicit overrides for both settings.

The existing translation-policy probe covers Vegas defaults and override
precedence. It passes, as do all seven app contract tests. Signed Release build
91 passes the production bundle validator and strict recursive signature
verification, and is installed on the physical headset. It retains build 90's
native memory84 libraries and current generated project configuration. The
first build invocation omitted the LLVM-MinGW environment required by the
bundle validator; the retry supplies it and passes all checks.

Build and device evidence is retained alongside the initial diagnosis.
Successful gameplay must be established separately from the identified
startup failure.

## Build 91 device retry

The automated desktop launch attaches StikDebug and reaches Wine at 23:00:19
headset log time. `runtime91-1.txt` confirms a 896 MiB executable pool and a
successful pool mapping for `GameAssembly.dll` at line 9839. There are no
`EXHAUSTED` messages or `Failed to load il2cpp` dialogs in this capture.
`Player91.log` now records Unity 6000.3.9f1 initialization, Direct3D 11.1 on
Apple M5, PhysX, and XR settings initialization.

The run then fails a 50 MiB FEX lookup-table allocation after 59 live tables
have consumed approximately 2950 MiB. `runtime91-1.txt` lines 14306–14310
show the null allocation, immediately followed by accesses to `0x1000000`.
The host had reserved its default 16 GiB translator arena. This matches the
previously observed Bigscreen failure and motivates applying its established
lookup/arena policy to Vegas in build 92.

Unity also reports missing optional/plugin dependencies including
`VCRUNTIME140_1.dll` and `SensApi.dll`; their effect on later gameplay and voice
chat is not established by the startup comparison.

## Build 92: picture and subsequent login failure

The physical retry confirms `mode=l1-only alloc=2MB` for translator tables and
successful game startup without the prior pool or lookup allocation failure.
The user first hears music with a black window, then reports that the picture
appears. Rendering is therefore not established as the cause of that initial
wait. The user subsequently reports **unknown login error and the app died**.
`Player92-picture.log` records `[VRPlatform_RuntimeManager] Error code: [4].
Platform callback jobs timeout`, followed by game cleanup. It also contains
repeated Unity TLS certificate-validation errors.

`game92-live1.txt` confirms the native importer loaded 121 public Mozilla roots.
However, `system92.reg` contains only five Windows root-certificate entries.
The native ARM64EC `enum_root_certs` removes and frees each certificate from
the shared host list. Later emulated processes see an empty host list, and
Wine's root-store synchronization deletes their previously imported roots.
The existing WoW64 enumerator already uses a non-destructive per-thread
cursor, but native ARM64EC callers bypass it.

Patch `0029-wine-reusable-root-certificates.patch` routes native enumeration
through that same cursor. Certificate verification and the bundled trust set
are retained. `test_root_certificate_enumeration.py` compiles the actual
enumerators and exercises repeated native/WoW64 walks, buffer growth and eight
concurrent callers under ASan/UBSan. `build_root_certificate_repair.py` builds
only `crypt32_unixlib.o` over the retained memory84 archive and verifies every
other object is byte-identical. Build/source receipts live under
`.build-device/vegas-infinite-diagnosis/root93-final/`.

## Build 93: trust repaired, avatar gate isolated

Build 93 retains 125 Windows root entries across Steam and game startup and
removes the observed Curl error 60 failures. Its remaining login failure is
`Platform callback jobs timeout`; the game then requests a normal shutdown.
The user confirms the same Steam account works on Windows.

Two absent dependencies, `vcruntime140_1.dll` and `sensapi.dll`, were built from
the pinned Wine source and installed into the prefix. This clears the missing
ToxMod/Vivox/Backtrace dependencies but does not independently clear the login
timeout. A separate fresh HTTP-cache trial also leaves the timeout unchanged;
the original registry cache paths were restored after that comparison.

Local inspection of the user's installed game identifies the platform-ready
gate waiting for its avatar-job dictionary to empty. Four jobs remain pending
while the game repeatedly calls `SteamAPI_ISteamFriends_GetLargeFriendAvatar`.
A scoped API adapter now permits the game's existing default-image behavior
when that API continues returning `-1` for five seconds. Valid image handles,
no-avatar responses, other error values and all other 858 named exports pass
through unchanged. The adapter retains all 859 export names and ordinals and
forwards authentication to the user's unchanged original Valve library.

The first complete adapter test (`avatar-fallback/Player-afc.log`, headset
start time 23:34:11) clears the ready gate, starts `22_Casino_Suite` loading at
23.4 seconds, and later initializes `ExternalRequestManager` and
`AccountLoginManager` with the user's account/session record. No platform-job
timeout occurs in this capture. The diagnostic app was subsequently stopped
to retrieve logs; this is evidence of login progress, not a completed VR
play-session test. The full native capture is `avatar-fallback/game2-complete.txt`.

## Build 94: repeatable installation

`build_vegas_avatar_fallback.py` builds the same tested adapter behavior from
source and validates the exact original-library SHA-256 and full export table.
It packages only the adapter and the two Wine dependency DLLs, never Valve's
original library. Build receipts and hashes are under `avatar94/`.

`VegasInfiniteCompatibility` prepares Steam app 886250 before Wine starts. It
validates resource hashes and the installed Steam API version, preserves the
original library beside both the executable and plugin, and records owned
files for later adapter updates. Unknown DLL versions, conflicting backups and
symlinks are preserved with an actionable launch error. Failed writes restore
the previous files. A Steam repair that restores the supported original DLL
is handled on the next launch.

The actual installer is tested for repeat launch, updates, Steam repair,
unknown versions, corrupted resources, symlinks, backup conflicts and partial
write rollback. The actual C API implementation is tested with controlled
Steam results and a clock under ASan/UBSan, including the five-second boundary,
recovery and bounded tracking. All eight app contract tests pass. Release
build 94 passes the bundle validator and strict recursive signature check.

The physical build-94 retry independently confirms the packaged installation:
all three installed DLL hashes match the package, and its ledger is present.
`Player94-3.log` reaches `VR_platform: InitCompleted_all true`, initializes the
platform runtime at 24.10849 seconds, starts `22_Casino_Suite` loading at
24.11566 seconds and opens the subsequent account-login panel. The app is left
running for the user to sign in. Full VR gameplay remains unverified. The
source/package/device receipt is `build94-receipt.json`. All 24 packaging tests
and the translation policy probe also pass.

## November 6: false newer-version message after updating

A subsequent download installs Steam build 26307654, depot 886251 manifest
3993298791555480662. Its Unity log identifies `CP178.7_Steam_178-1`, confirms
refresh-token login and successful account-detail retrieval, then stops in
`GameConfigurationManager` while the user sees a newer-version message.
Re-downloading therefore did update the running game.

Static inspection identifies a build-hash comparison in that initialization
stage and ACTk code hashing of DLL, EXE and IL2CPP metadata files. The avatar
adapter changes a game DLL and adds other DLLs to the checked game tree. This
makes the adapter unsuitable for this game even though it clears the earlier
avatar gate. Do not bypass the integrity check or falsify the client version.

Build 96 retires automatic adapter installation. Before launch it restores the
verified original Steam API only when the installed file matches the retired
adapter, removes only verified adapter-owned backups/dependencies and removes
the migration ledger. Newer Steam DLLs and unrelated files are preserved. The
Wine-prefix dependency DLLs, memory policy and native certificate repair remain.
The migration tests cover original restoration, repeated launch, newer genuine
DLL preservation, unrelated/conflicting files, missing backups, symlinks,
corrupt resources and partial-write recovery. All eight app contract tests pass.
Physical retry and login/gameplay results must be recorded separately.

Build 96 is installed and its device preflight ran successfully. The restored
Steam API SHA-256 is independently verified as
`b8246e1a629b945fe526b24c3e4f002c4f6eb86aa1b5ed9744399f22a0d2ca9f`.
A recursive device listing confirms both original-library aliases, both
game-local Wine dependency DLLs and the adapter ledger are absent. The retry
is blocked before Wine starts: after the headset restart, StikDebug cannot
reach its LocalDevVPN endpoint (probe timeout). The user was asked to reconnect
the VPN. No post-cleanup gameplay or version-check success is claimed.
The installation and verification receipt is `version-check/receipt96.json`.

## Original Steam resources fix the avatar timeout

The original Steam client references `graphics/avatar_32blank.tga`,
`avatar_64blank.tga` and `avatar_184blank.tga` for default profile pictures.
The three minimal binary packages used by WineVision omit these files, and
they were absent from the headset's Steam folder. Valve's verified
`resources_all.zip.c0054b3a54e3b8d249a38022ccc94ba655c55eae` contains all three.
Its size is 3,493,173 bytes and SHA-256 is
`6679e6b4866758ccd33bcb9cbcbf47a1531c24e67c85a3005e97bddf1acf7c82`.
The exact resource hashes are recorded in `SteamRuntimeFiles.avatarResources`.

After copying only those original images into Steam/graphics and verifying
the device bytes, the original game DLLs pass platform initialization at
15.10888 seconds, account login at 19.51095 seconds and game configuration at
25.37507 seconds (`version-check/Player96-resources2.log`). The user confirms
login progress and now sees an anti-cheat prompt. No game DLL changes or
version/integrity-check overrides are used. The temporary proxy is retired.

Build 97 adds a generic pre-launch repair for missing default Steam images.
It downloads the pinned official package only when needed, verifies the
archive and extracted images, preserves existing resources and publishes
complete files without replacing existing destinations. The actual Valve
archive passes the production Swift ZIP parser; its 614 entries require
raising the bounded entry limit from 256 to 2048. Ten app contract tests pass,
including missing-file repair, repeated launch, corruption and symlink checks.

## Public launch path and anti-cheat

Steam's current cached metadata exposes public entries 0 (VR) and 8 (desktop),
both through `PokerstarsVR_Bootstrap.exe`. Entries 1/2, 9, and 10/11 belong to
internal/QA, Deck and penetration-test branches. The selected 9 entry starts
the game directly. The parser previously missed the capitalized `BetaKey`
field, and installed-file filtering did not restrict branches. Build 97 reads
that field without case sensitivity, filters to public Windows entries and
migrates a saved private option to a public option with the same arguments.
The public bootstrap requires .NET Framework 4.7.2. Wine Mono 11.0.0 is being
prepared using the retained runtime's pinned installer, independently of the
game directory. Public-bootstrap and anti-cheat results remain to be verified.

## Build 97 final device result

The user reports: `EAC Error: Can not find AntiCheat Client, did you start
the game from Anti-Cheat protected exe?` This matches the direct Deck-branch
entry used in the preceding run. Build 97 is signed, installed and independently
verified. Its automated retry migrates the saved entry to public desktop
option 8, confirms Steam default images are present and retains the genuine
game API. It then refuses before Wine/JIT startup: the public bootstrap is an
i386 managed EXE (CLR flags 0x20003, .NET Framework 4.7.2), and this packaged
runtime lacks `Runtime/i386-windows/ntdll.dll`. No retained matching i386 ntdll
package was found. Wine Mono 11.0.0 was installed and its core hash verified,
but that cannot supply the missing 32-bit Windows runtime.

Protected launch and gameplay therefore remain unsupported by this installed
build; anti-cheat compatibility has not been established. Do not revert to
private/no-EAC entries or modify the game checks. The measured original-file
run demonstrates repaired startup, login and build configuration, not protected
gameplay. `version-check/receipt97.json` records the final source, resource,
dependency, test and device results.
