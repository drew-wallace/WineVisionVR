# Steam on the research headset app

The native **Steam library** sheet signs in to Steam, lists owned games, and
downloads their Windows depots directly into the headset's private Steam
library. It does not download a second copy to the Mac. Sign-in supports
password/Steam Guard and QR approval. Tokens use the device-only Keychain;
passwords, codes and tokens are excluded from diagnostic messages.

In the library menu choose **Prepare Valve client** before selecting a game
to play. This downloads the exact client packages supported by Madeira Dock
from Valve's CDN and verifies their sizes and SHA-256 hashes. Other client
versions are rejected. No Valve client binaries are distributed with the app.

Choose a game's artwork card to open its square download panel. **Close** is
always available in both the panel and library, including after network errors.
The panel shows artwork, progress, transferred bytes, speed and a per-game error.
Choose **Download**, **Pause**, **Resume** or **Retry download** there. Completed
chunks are verified and journaled; retries resume those chunks, and the Steam
install record is written after completion. Downloads need sufficient headset
storage and an active app. This port does not promise background downloads.

After installation, choose a game's **Play** menu and the desired Windows/VR
launch option. This selects the game in the research launcher; then press
**Launch game** there. The launch prepares the debugger/JIT and immersive
compositor first. Native downloads pause and their Steam connection logs off
before Valve's Windows client takes the account. Dock receives its token in a
protected, single-use file, outside Documents, rather than the manifest or argv.
The runtime still has one session per app process; restart after session exit.

Dock is a headless Windows host for Valve's own client libraries. It performs
Steam launch and license handling, while OpenComposite and the project-owned
OpenXR bridge provide the intended VR transport. This does not run the complete
Windows SteamVR desktop runtime, and it does not establish compatibility with
every SteamVR game. D3D11 is the initial Steam launch profile. Games requiring
additional launchers, one-time redistributable installers, anti-cheat or other
unsupported platform services may fail. Steam Cloud synchronization is described below. Madeira's one-time installer
orchestration has not been ported.

The shared Steam prefix is
`Documents/WindowsVR/Prefixes/<SHA256("steam.shared")>/`; downloads live under
its `drive_c/Program Files (x86)/Steam/steamapps`. Different Steam games share
this prefix so the client can resolve their install records.

## Source and build

Steam sources are adapted from Madeira revision
`48f976429c189f8396e23d251d8a82f43c705922`. Their GPL notices, converter exception,
and provenance are in `third-party/steam-native`. Madeira Dock is built from
revision `72558e416a390f3669457930f09a389e54f49556`; its source, license and
cross-compiler runtime notices are preserved in the generated `dock-notices.txt`.

The normal assembler builds Dock automatically from the original pinned Git
checkout, whose submodule metadata is retained. For that source checkout:

```sh
AVPPLAY_MADEIRA_STEAM_SOURCE=/absolute/path/to/pinned/Madeira \
AVPPLAY_LLVM_MINGW_ROOT=/absolute/path/to/llvm-mingw \
bash windows-vr-tools/build_steam_dock.sh
```

Generated Dock binaries and receipts are excluded from Git. The app embeds
`Resources/arm64ec-windows` for Madeira's resource lookup; despite the folder
name, this Dock executable is x86-64 PE and runs through FEX.

Compilation and installation are separate from live Steam verification. No
Steam sign-in, client launch, game download or game execution was performed
during this implementation. Game rendering, licensing, child-process behavior
and sustained performance remain unverified on Vision Pro.

## Cloud saves, DLC and online services

Build 22 restores Steam Cloud before each actual game launch, including games
selected from a saved launcher profile, then releases the native connection
before Valve's guest client signs in. It synchronizes again only after Wine and
its server have stopped. A pending-upload journal survives a crash, app closure,
or network failure and retries when the account reconnects on the next app run.
The game's Steam panel also offers **Sync saves** and **Use cloud saves**.

**Reset saves**, beside **Use cloud saves**, requires a destructive-action
confirmation. It durably disables uploads and downloads, disables Valve's
combined per-game Cloud switch, clears pending uploads and the comparison
baseline, then removes only that game's mapped Windows save files, Steam API
save files and `remotecache.vdf`. A read-only cloud listing identifies mapped
files; reset never sends an upload or cloud deletion. All local paths are
validated before removal; unsafe mappings, symbolic links or a failed listing
leave the local files in place with sync off. Wine must be stopped. Unrelated
games and installed DLC are preserved. An interrupted older sync is invalidated
even if permissions are later re-enabled. After reset, enable downloads and use
**Use cloud saves** to restore; uploads cannot resume before a successful cloud
restore establishes a new baseline. Existing archival backups remain outside
the game's active save folders.
The latter restores conflicting files from Steam; overwritten files are backed up
in `Library/Application Support/SteamGameServices-v1/Backups` in the app container.

The migration intentionally clears existing local saves the first time each
account/game is synchronized, then restores the cloud version. All cloud downloads
are staged and checksum-verified before that reset. The first restore never
uploads, including when the cloud is empty. Only Steam's declared Windows save
patterns and that account/game's `userdata/.../remote` files are removed; unrelated
prefix files are retained. The sync cache for that game is cleared locally.
There is no cloud-delete request. Subsequent syncs compare SHA-1 baselines;
changes on both devices block launch until resolved. API saves in `remote` and
Steam Auto-Cloud roots/Windows overrides are supported. Unmapped roots, encrypted
transfers and unsafe paths fail with a visible error. Games that do not advertise
Steam Cloud support skip cloud synchronization.

DLC ownership comes from the authenticated account's Steam licenses, refreshed
at launch. Downloads select only owned DLC depots, including content published
under a child DLC app, and preserve `dlcappid` in the install record. Successful
downloads and repairs immediately refresh and verify DLC status, independently
of save synchronization; incomplete owned DLC reports an installation error.
**Use cloud saves** does not download DLC. The panel
shows owned content and whether its selected depot manifests match the installed
record. Missing/outdated owned DLC blocks launch with **Update / repair** guidance;
DLC with no separate Windows depots uses the base game's content and Valve's
runtime entitlement checks. A Steam manifest records installation; it is not
proof that every DLC has been exercised successfully in gameplay.

Online games continue through Valve's genuine client, which stays alive and
pumps callbacks while the game runs. The launcher shows Valve's reported online
sign-in and detects loss of a network path. Native library/download/cloud sessions
are disconnected during play to avoid taking the guest's account session. Steam
matchmaking, networking and game servers remain the game's responsibility; this
integration does not supply game-specific services or anti-cheat compatibility.
See Valve's [Steam Cloud documentation](https://partner.steamgames.com/doc/features/cloud)
and [DLC documentation](https://partner.steamgames.com/doc/store/application/dlc).

Validation: `python3 visionos-windows-vr/Tests/SteamServices/run.py` exercises the
production sync/metadata code against a scripted Steam transport, without account
access. It covers cloud-first reset, upload/commit, backups, durable retry,
conflicts, account isolation, path escapes and DLC selection/readiness. These checks
and visionOS compilation do not establish live cloud or multiplayer compatibility.
On October 29, 2026 the existing Slay the Spire 2 local save/cache directory was
cleared from the physical headset while the app was closed and verified empty
apart from a restore-required marker and empty `remote` folder. No Steam Cloud
mutation was performed as part of that cleanup.

## Build 23: save direction controls and library recovery

Each game's Steam panel has independent **Upload saves** and **Download saves**
toggles. They are stored per Steam account/game and apply to automatic sync and
**Sync saves**. **Use cloud saves** requires downloads to be on and never uploads.
Both off skips the cloud service entirely. A disabled direction leaves that side
unchanged, and does not require equality with the intentionally unsynchronized
side. Upload permission is checked before opening the batch, before each block,
and before committing. Cloud overwrite backups are downloaded only when
Download saves is on; upload-only mode does not fetch cloud file bytes.

Valve's client has one combined per-game Cloud preference. With either direction
off, the launcher disables the guest client's automatic Cloud sync in that
account's `localconfig.vdf`, while native sync handles whichever direction is
allowed. Settings are changed with Wine stopped, and the preference is checked
again before launching the guest. Other client settings are preserved. Toggles
are unavailable while a guest session is active. These controls apply to Steam
Cloud, not a game's independently operated account/save service.

For the current download check, Slay the Spire 2 uploads were temporarily turned
off and its pending retry was cleared. There is no special case for its App ID:
the normal Upload saves toggle can re-enable uploads after the user confirms the
cloud download. The existing local saves and sync baseline were retained.

A failed pending save retry no longer fails the owned-library refresh or prevents
the download queue from being restored. Failures are shown against the affected
game while the library remains usable. Installed content and save checks reuse
the full product metadata fetched by the current refresh, instead of making
redundant PICS requests. This cache is replaced on refresh and invalidated across
account changes. Missing install records and missing server metadata now have
different messages; neither error tells the user to repeat a successful library
refresh indefinitely.

Build 24 also supports PICS records delivered by HTTPS instead of inline VDF.
Steam's returned host/digest selects the metadata file; gzip output is bounded
and checked against the PICS SHA-1. Requests run in groups of eight, and unchanged
digests reuse the already parsed metadata. This fixes catalogs where most apps,
including installed games, had an empty inline buffer and were omitted on every
refresh. Metadata downloads are independent of save-download permissions.

## Build 26: local Installed library

**Installed** reads completed `appmanifest` records from the headset directly,
including on first opening the library, before a Steam refresh returns. An empty,
failed, or ongoing remote refresh cannot remove those installed cards. Steam
metadata enriches artwork and launch options when available, while local install
records remain authoritative for membership and install paths. Pull-to-refresh
on Installed rescans local records and completes without waiting for the remote
catalog. The tab can also be browsed while signed out; signing in is still
required to launch.

Installed game panels use existing launch metadata or the guest client's local
appinfo cache. If neither is available, opening the panel fetches product info
for that one game, independently of the full library refresh. Launch still runs
the existing account, DLC, and permitted cloud-save checks. Save upload/download
preferences are unaffected by browsing or refreshing Installed.

## Build 27: Steam friends presence

The headless guest host now initializes the genuine client's social presence
only after Valve confirms an online sign-in. While the game runs it moves
inactive Offline/Away/Snooze states to Online. Busy, Invisible, Looking to Trade,
and Looking to Play states are preserved. Offline launches skip this path.
`MADEIRA_STEAM_ONLINE_PRESENCE=0` disables the presence initialization.

Numeric report fields distinguish authentication from friends-session readiness:
`session-social-interface-ready`, `session-social-previous-state`,
`session-social-online-requested`, `session-social-persona-state`, and
`session-social-friend-count`. The launcher reports the client's actual presence
and whether a friends list is available. These are diagnostics, not proof that
a friend's lobby is reachable. Friends' identities and lobby IDs are never logged.

The new private calls are restricted to the already supported January client
SHA-256 `71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640`.
Independent PE/RTTI/disassembly inspection binds CSteamClient slot 13 (RVA
`0x943510`) to CUserContext's `+0x20` field; the constructor at `0x9ed414` stores
the IClientFriendsMap constructor's result in that same field. The map's slots
4/5/7 are GetPersonaState (`0x768a20`, IPC `0x534bc194`), SetPersonaState
(`0x848460`, IPC `0xe333cf87`), and GetFriendCount (`0x752d60`, IPC `0x1e61eaea`).
The getter takes the object pointer plus two 32-bit user/pipe handles; state and
friend-flag arguments/returns are 32-bit. Every method pointer is checked against
the exact module-relative address before use. Other client builds skip social
initialization rather than guessing these interfaces.

Reproduce the portable policy/sanitizer tests and optional read-only ABI check:

```sh
python3 windows-vr-tools/test_steam_presence.py --client /path/to/steamclient64.dll
```

This patch and the bounded-arguments patch are applied in order to a temporary
copy of the pinned Dock source. The generated Dock receipt includes both patch
hashes and every patched source hash. No downloaded Valve binary is redistributed.

For the reported Slay the Spire 2 issue, logs confirmed Steamworks initialization,
online authentication, and v0.107.1; the user confirmed their friend's matching
version and friends-joinable lobby. Presence was missing from the original host.
Friend-lobby discovery and a completed multiplayer session still require a live
retry with the friend's lobby; status changes alone do not establish that result.

For a device presence check, the existing automated Steam launch can additionally
set `WVR_STEAM_SOCIAL_PROBE=1` (only honored when automated launch is enabled).
That probe skips native cloud sync and sets Dock's existing launch flag to zero.
Valve still authenticates and checks the license, reports presence/friends, then
exits without starting the game. This is a diagnostic path, not a multiplayer or
lobby-connectivity test.

Build 28 explicitly announces Online on the first friends poll even if the
client already reports Online locally, then only refreshes inactive states.
The login-only device probe verified this client adapter and read 29 friends
without submitting a game launch or invoking native cloud sync. A local Online
result alone is not treated as proof that the state was published remotely.

## Build 29: engine activity and managed HTTPS

The build 28 retry still appeared Away remotely. Persona state is insufficient:
the January engine maintains a separate computer-idle timer and auto-away checks.
The host now calls the genuine client's SetComputerActive with its VR activity
source on the existing five-second online-session poll. This runs only while the
host owns the authenticated session, and stops when that session ends. Busy and
Invisible persona choices remain intact; offline sessions skip social setup.

This additional ABI is gated by the same full client SHA-256. CSteamClient slot
14 (`0x945220`) takes the pipe handle and returns IClientUtilsMap. Slots 5 and 6
are GetSecondsSinceComputerActive (`0x76f3b0`, IPC `0xb0a5e101`) and
SetComputerActive (`0x83a060`, IPC `0xf0bc0b28`). The latter serializes one 32-bit
source argument. The engine's activity-source switch at `0x962238` maps value 2
to `VR`. Older reconstructed headers describe a no-argument call and must not be
used for this client. Runtime checks verify the factory and method addresses
before use. Numeric activity-ready and idle-before/idle-seconds reports show
whether this path is available and whether the timer reset. They do not establish
what another Steam session sees or whether a multiplayer connection succeeded.

The game log also showed repeated .NET TLS failures loading Normaliz.dll before
server-time requests. The runtime now builds and requires Wine's normaliz target.
Wine emits this target as a data-only AMD64 forwarder with no entry point or
executable sections; the final bundle validator requires that data-only
shape for normaliz.dll. Its exports forward to the existing kernel32 NLS
functions. No Microsoft DLL is downloaded or redistributed.

The isolated managed probe exercises international hostname conversion. With
`run_compatibility_probe.py --probe managed --managed-https`, it also performs a
certificate-validated HTTPS request to Valve's public server-time endpoint. The
probe has its own prefix, never starts a game, and does not invoke Steam Cloud.


## Build 31: client frames and friend-game diagnostics

The user's working Klepton setup provided a local reference: its session owner
calls the genuine client's frame function before draining callbacks. Dock had
only drained callbacks. The new ordered host patch services the January private
CSteamClient RunFrame (slot 19, RVA 0x945e30) on the owning thread before each
callback batch in login, offline login, custom-binary preparation and game wait.
It verifies the existing full client SHA-256 and method address, clears the pump
before user/pipe teardown, and emits ready/tick counts. The public SteamClient021
ABI is different and is never used for this private call. Unsupported versions
skip the call; MADEIRA_STEAM_RUN_FRAME=0 permits a controlled comparison.

Additional diagnostics count friends playing any game, playing the selected app,
and advertising a nonzero lobby for that app. A boolean reports whether the
client's own friend-game record matches the selected app. No friend identity,
network address, lobby ID or game name is written to the report. Reads are
limited to 256 friends and one snapshot per five seconds.

These calls have the same exact-client gate. IClientFriendsMap slot 10 is
GetFriendByIndex (0x7526f0, IPC 0x272df28d), with the MSVC hidden return buffer in
RDX and index/flags in R8D/R9D. Slot 23 is GetFriendGamePlayed (0x753250,
IPC 0xe0ce182e), taking a 64-bit ID value and a 24-byte FriendGameInfo output
(lobby at offset 16). Device and static checks must establish actual results;
loading the friends interface alone is insufficient evidence of lobby discovery.

The existing automated login-only social probe now observes an authenticated
session for twenty seconds. It never calls the game launch path or native cloud
sync. This permits friend metadata to arrive and allows a frame-on/off comparison
while a friend's lobby is open. A completed multiplayer connection still requires
an actual join; the diagnostics do not claim one.


The frame-on/off device comparison authenticated and loaded 29 friends in both
cases, but received zero friend-game/lobby records while a friend's lobby was
open. RunFrame alone is therefore not treated as the fix. The subsequent build
32 asks the genuine client for full user information once per immediate friend
(up to 256), through RequestUserInformation(false). It reports readable ID,
online friend and queued-request counts to distinguish a cache/subscription
failure from an enumeration ABI failure. The additional private method is slot
32 (0x82e020, IPC 0xbc9a7cbb), with the ID in RDX and bool in R8B. Slot 13
GetFriendPersonaState (0x7542b0) reads persona state without changing it. No
requests are repeated for an already requested ID within that host session.


Build 32's device probe read 29 nonzero friend IDs and queued 29 full-information
requests, but still reported zero online friends and zero game/lobby records.
This is explicitly not a successful discovery result. Build 33 adds a bounded
Windows message pump before each private frame call. It dispatches at most 64
messages per cycle, counts total messages/timers without logging payloads, and
stops pumping at teardown. The comparison knob MADEIRA_STEAM_MESSAGE_PUMP=0
keeps private frame calls enabled but skips Windows message dispatch. This tests
whether hidden-window/timer processing was missing from the console host.


The build 33 message probe dispatched zero messages/timers and still received no
live friend records. Build 34 adds an opt-in friends-only reconnect comparison:
MADEIRA_STEAM_SOCIAL_RECONNECT=1 changes Online to Offline for 1.5 seconds, then
returns to Online, using the genuine client. Busy/Invisible choices are retained.
The default remains unchanged pending live evidence. GetFriendPersonaName (slot
14, 0x753c20) permits matching a diagnostic target supplied only by environment;
only match counts and boolean online/game/lobby results are logged, never names.


The opt-in reconnect completed, read all 29 names, and matched the supplied
friend, but that record still had offline/no game/no lobby. Build 35 adds an
opt-in primary chat destination comparison through the genuine user interface:
MADEIRA_STEAM_CHAT_DESTINATION=1 calls IClientUserMap slot 27
SetSelfAsChatDestination(bool) (0x84c300) and records slot 28
IsPrimaryChatDestination (0x8166f0) before/after. Both addresses are independently
verified under the January SHA gate. This routes incoming Steam activity; it
sends no chat or invitation. The default is unchanged pending live evidence.


The resumed build 35 probe became the primary chat destination (0 -> 1), but
still had no live friend/game/lobby data. Build 36 optionally creates a separate
public Steamworks connection before login, matching the Klepton host lifecycle:
MADEIRA_STEAM_PUBLIC_CLIENT=1 creates a pipe, connects to the existing global
user, and obtains SteamUser023 and SteamFriends017 through SteamClient021. It
drains only that additional pipe and releases its user/pipe before backend
teardown. Authentication/ownership remain the genuine client's decisions. Public
and private game-info counts are observed separately. The January adapter
addresses are verified independently; this comparison is opt-in pending evidence.


The public-connection probe matched the global user, initialized User/Friends,
drained 601 callbacks, and released the extra pipe, but still had zero live
friend/game records. After the friend confirmed Online status, visible game
details and an open lobby, build 37 added an original-game-SDK comparison. This
is enabled only by automated WVR_STEAM_SOCIAL_PROBE=1 and
WVR_STEAM_SDK_PROBE=1. The native cloud stage remains skipped. After genuine
online authentication, license confirmation and install-directory validation,
the host temporarily publishes its existing Steam discovery registration and
loads the original installed SDK at MADEIRA_STEAM_SDK_RELATIVE_PATH (bounded,
relative, no parent traversal). It initializes that owned app's context through
SteamAPI_InitFlat, verifies the SDK's real app ID and online user, pumps the
original callbacks and reads the public flat Friends APIs for 25 seconds. It
never invokes LaunchApp, the game executable, CEG installers or RemoteStorage.
It shuts down the SDK and restores the existing discovery registration. No
Valve SDK binary is added to this repository or app bundle.


Before running that SDK comparison, build 38 requires the genuine per-app
combined Cloud preference to be off. Under the January SHA gate, engine slot 24
(0x9445f0) returns context +0x68, IClientRemoteStorageMap. Its slots 24/25
IsCloudEnabledForApp (0x814250) and SetCloudEnabledForApp (0x839830) take the
explicit app ID, with a bool on the setter. The diagnostic disables and verifies
the flag before loading the SDK, and fails without loading it if the flag cannot
be confirmed off. These are settings calls only, with no remote file transfer
calls. Native upload/download permissions remain unchanged.


The original SDK loaded with Cloud disabled, but InitFlat returned 3 (version
mismatch), without launching a game. The installed Steamworks.NET wrapper instead
calls SteamInternal_SteamAPI_Init(NULL, error), creates SteamClient021 and gets
SteamUser023/Friends017/Utils010 explicitly, then uses manual dispatch. Build 39
matches that initialization and callback path. The broader InitFlat failure is
not treated as proof of a game incompatibility. Both probes leave license checks
with Valve and never override an SDK result or substitute an interface.


That initialization also returned 3 inside the backend host. Build 40 moves the
same SDK comparison into a separate Windows client process, which connects to
the authenticated parent just as a game does. The existing host executable's
--sdk-network-child entry returns before backend/login startup; it never reads
the handoff credential. The parent retains its genuine auth/license gate,
disables automatic Cloud before spawning, pumps the backend while the child
runs, and restores discovery after the child exits. A failed SDK init writes
only its bounded error to a private diagnostic file for targeted inspection.
The child still never starts the game or accesses remote save files.

The separate-process SDK probe initialized successfully with the correct app,
online user and all 29 friends, but no live status or lobby records. This ruled
out SDK initialization as the cause of this lobby-discovery failure.

Build 41 identified the missing live-status subscription. Valve's
[Chat service definition](https://github.com/DoctorMcKay/node-steam-user/blob/master/protobufs/steammessages_chat.steamclient.proto)
defines `Chat.RequestFriendPersonaStates#1` with an empty request and delivers
updates through `CMsgClientPersonaState`. The real authenticated Windows client
accepted the request (EResult 1), then reported 9 online friends, 3 playing games,
and the diagnostic friend's correct app and nonzero lobby. Before that request,
all live values were zero despite cached names and successful sign-in.

Build 42 sends this subscription during normal online startup. It uses the
January client's independently verified CSteamClient slot 52 (0x945040), which
returns CUserContext+0xc8 / IClientUnifiedMessagesMap. Its SendMethod,
GetMethodResponseInfo and ReleaseMethod slots 0/1/3 are 0x832ff0/0x762330/0x827170.
The complete client SHA and each method address are checked before calling.
The request is issued once per online connection, with a bounded response wait
and handle cleanup at completion or teardown. `MADEIRA_STEAM_FRIEND_SUBSCRIPTION=0`
is a diagnostic opt-out. This requests status only; no chat messages, invites or
save APIs are called. The launcher waits for a successful subscription before
reporting Friends connected; cached names alone no longer imply that readiness.

Hosting follow-up: joining a friend's real game now succeeds, but friends still
see this account as Away and do not discover its hosted lobby. An opt-in primary
chat destination test changed the local flag 0 -> 1; it did not establish a fix.
During that run, the app entered the background and audio deactivated. Steam's
connection subsequently closed and CreateLobby returned EResultNoConnection.
The primary destination option was removed from the next test launch; it remains
disabled by default. Audio interruption evidence is retained separately.

Build 43 adds an automated-only `WVR_STEAM_LEGACY_FRIENDS=1` comparison, passing
Valve's `-nofriendsui` option to the host in both installer and direct startup
paths. On the exact January client, SetPersonaStateInternal calls the no-argument
bool helper at 0x68f550 in friendsuihelpers.cpp: its true path posts a desktop UI
event, while false updates the client's desired state. The helper honors the
explicit -nofriendsui option. A read-only numeric mode check and Offline/Online
setter readbacks distinguish actual client changes from merely requesting one.
This comparison changes no Valve binary or game code and remains opt-in pending
physical evidence. The live-friend subscription and save direction settings
are retained.

Build 44 physical readback still reported web UI mode 1; requesting Offline also
read back as Online (1). Inspection showed the -nofriendsui comparison had been
added to an unused legacy launch helper, so that run did not test the intended
client option. Build 45 adds the argument to effectiveManifest after saved
profile/draft reconciliation, the path actually serialized to the runtime. The
host reports only whether that exact argument arrived (never argv contents),
then the existing client mode and state readbacks establish its effect. The
unused helper is restored. The option remains restricted to automated tests.

Build 45 confirmed client-no-friends-ui-argument=1 and session-social-web-ui=0.
The genuine Offline setter now reads back 0 (the ineffective UI path stayed 1).
After the existing active-VR idle reset, the genuine client reads back Online.
An independent HTTPS query of the account's public Steam Community profile
reported `onlineState=in-game` and named Slay the Spire 2. No credentials were
used for that public read, and only those status booleans were retained.

Build 46 passes -nofriendsui on every Steam host launch, including restored
profiles, without duplicating an existing argument. It no longer depends on the
automated test environment. The optional diagnostic Offline/Online reconnect
remains off by default; Busy and Invisible handling is unchanged. The live
friends subscription remains enabled. Hosting gameplay still requires a remote
friend's join confirmation; local state alone is not that confirmation.
