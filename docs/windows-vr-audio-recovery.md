# Audio focus and loading investigation

The user reports intermittent headset-wide static through the built-in speakers
in both Slay the Spire 2 and Risk of Rain 2. Closing the game window suppresses
it; reopening can restore the distortion. Force-quitting clears it temporarily.
The user suspects focus loss and loading increase its frequency but is not
certain. This is not established as a Tab-specific issue.

The October 30 Risk of Rain 2 launcher log records audio deactivation at
23:32:40, then reactivation at 23:34:27, without an automatic output restart.
The old observer only recovered on a separate `shouldResume` recommendation.
It logged actual activation without rebuilding the runtime's output resources.
That is a recovery gap, not proof of the cause of spontaneous static.

## Host lifecycle candidate

`WindowsVRAudioRecoveryCoordinator` now tracks actual audio deactivation and
rebuilds output once the session reactivates. It uses the existing native
`wvr_audio_output_reset_v1` from build 50 onward. It retains the separate
system-recommended activation path and manual Reset audio control.

Normal window focus changes do not mark audio as interrupted. Automatic
recovery defers while the app is backgrounded, checks its actual application
state before acting, and respects a recommendation not to resume. Duplicate
activation/recommendation events coalesce. A stopped runtime does not recover,
failures do not create automatic retry loops, and an interruption during an
in-flight restart remains pending for its own recovery cycle.

Notification callbacks capture arrival time before dispatch to the main actor.
Snapshots log delivery delay, application state and thermal state alongside
the existing audio route/rate/buffer information. These can help distinguish a
late main-thread handler during loading from an audio-session transition.

## Validation and integration

Run `python3 windows-vr-tools/test_audio_lifecycle.py` for executable policy
tests, or add `--simulator <visionOS-27-simulator-UUID>` to exercise the actual
notification observer on visionOS with only the native restart stubbed.
Both pass; the host audio sources also pass Swift 6 type checking against the
visionOS 27 device SDK with warnings treated as errors. These checks do not
establish audible recovery on the physical headset.

This candidate changes shared host Swift audio code only. It does not change
Wine/FEX, graphics patches, game profiles, native archive provenance, project
versions, `dist/current`, or the installed headset app. The Risk of Rain 2 crash
chat retains ownership of the combined build and device test. Its usual
XcodeGen rebuild includes the new coordinator from the Sources directory.

During the next combined game test, compare loading while focused with loading
while another window has focus, then return to the game. If static occurs,
note the approximate time and whether Reset audio clears it. Correlate this
with the new notification-delay and automatic-recovery log entries. Static
without a matching audio-session transition remains an open investigation.

## October 31: head-turn background transition

The user reports another freeze when turning their head away from the game,
without intentionally switching apps. The build-56 launcher log records the
window/app backgrounding at 15:08:43 and foregrounding at 15:08:45, followed by
actual audio reactivation and output recovery. This establishes a lifecycle
transition; it does not establish that it caused the earlier 53.9-second stall.
The live capture is retained in `.build-device/risk-of-rain2-title-fix/freeze-live/`.

Both app specifications omitted `UIBackgroundModes: audio`, although the host
already uses AVAudioSession playback and the Wine backend produces real game
audio. Build 57 declares that supported mode in both specifications so ongoing
game audio can continue when the window is out of view. Controller routing
continues to respect scene activation. No native translator, graphics package,
JIT protocol or audio recovery policy changes are included in this candidate.
The original minute-long process stall remains unresolved until a focused and
head-turned device comparison verifies the behavior.

Apple documents that windows can enter the background when placed behind the
viewer, and that background audio is a supported execution mode on visionOS:
[window lifecycle](https://developer.apple.com/documentation/foveatedstreaming/creating-a-foveated-streaming-client-on-visionos),
[background execution modes](https://developer.apple.com/documentation/xcode/configuring-background-execution-modes).

The previous run's full archived log confirms another 53.8-second stall,
15:07:29.735–15:08:23.521, with a 53,786 ms profiler interval. This precedes
the observed 15:08:43 background transition, so that transition cannot establish
the cause of the long stall. The archive was recovered and its alias restored
as a byte-verified independent copy without changing the current active log.
Build 57 passes signing, production packaging, core/app checks and inspection
of its actual built Info.plist (`audio` plus both existing controller profiles).
The user requested leaving the current session open, so it is not installed.
The suspected debugger involvement is supported by similar prior Madeira source
notes, but no new stop/departure trace proves it in these captured runs.

## Focused freeze: debugger memory-limit termination

The user reports recurrence while the game retained focus. A device unified-log
archive records StikDebug PID 8424 terminated at **15:17:48 on October 31** with
`domain:jetsam(1) code:per-process-limit(7)`. A separate event explicitly says
`isUserKill:0`, and the system reports `Process StikDebug [8424] killed by jetsam
reason per-process-limit`. This is a memory-limit termination of the debugger
helper, rather than evidence that the user looked away or manually quit it.

The retained Madeira `ContentView.swift` (ml524/#67) documents roughly 54-second
whole-task stalls after debugger departure, including clean exits and kills.
That known behavior and the current helper termination make debugger loss a
strong explanation for this recurrence. The helper's memory growth and this
active run's exact native pause boundaries still need to be established.
The CS_DEBUGGED flag in the freeze detector is sticky and does not prove a live
debugger is still attached after its helper exits.

Build 57's background-audio declaration addresses a separate confirmed lifecycle
omission; it is not a demonstrated repair for debugger memory exhaustion.
The user requested preserving the current session; this chat performed no
installation, restart or debugger attachment. Device trace and filtered
termination evidence are under
`.build-device/risk-of-rain2-title-fix/freeze-focused/`.
