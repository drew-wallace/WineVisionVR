# Desktop pinch clicks — November 5, 2026

After confirming Balatro gameplay and audio recovery, the user reported that
one pinch sometimes only moves the cursor. A second pinch clicks the item, or
a pinch at a different location selects the previous cursor target.

The input trace shows cursor movement and button-down combined in one event
(`0x8003`). Pinches need not provide advance mouse-hover frames. Balatro's
controller chooses a mouse press target from its previously established hover
state, so teleporting the cursor and pressing during one guest update can
select the old target. Quick down/up sequences can also reach a single guest
event-pump iteration. Release handling additionally supplied new coordinates
without the MOVE flag; Wine's server ignores those coordinates in that case.

`WindowsDesktopPointerInput` now sends movement first, allows two subsequent
guest presentation submissions before pressing, and keeps a quick pinch held
through two subsequent submissions before releasing. The first submission can
already be in flight. Wall-clock fallbacks bound the wait for GDI windows or
paused renderers (150 ms before press; 100 ms before release). All desktop
touch buttons use this sequencing, including indirect pointing input, so a
visionOS gaze pinch cannot bypass it through touch classification. Button-up
includes MOVE so its actual release coordinates reach Windows.

Each gesture retains its origin and release point. Early drag motion is
buffered until the initial press can be handled. Rapid pinches queue with their
own targets. Focus loss, cancellation, or detachment removes pending gestures
and releases an already emitted button. Hover events cannot relocate an
unfinished gesture's press target.

A desktop-only Metal presentation counter provides timing without waiting on
the GPU, reading textures, capturing images, or writing diagnostics. It chains
the existing presentation implementations and excludes nested calls from
double counting. No game scripts or game executable are changed.

Run `python3 windows-vr-tools/test_desktop_pointer.py` for the production Swift
sequencer regression. It exercises the observed stale-hover target behavior,
quick and queued pinches, drag anchoring, release coordinates, cancellation,
no-frame fallback, and right-button pairing.
Build 90 passes the pointer regression, desktop presentation contract, device
Release build, and code-signature verification. The update was installed at
the user-confirmed safe stopping point. Balatro
relaunched with the debugger attached and its 1920×1080 client visible in the
launcher log. The user confirmed: “First pinch and dragging both work.” Physical
first-pinch selection after changing gaze targets and card dragging both pass
on build 90.
