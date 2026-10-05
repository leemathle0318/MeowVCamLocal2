# Verification — local-only revision 0.4.0

User report about 0.2: selecting a video disabled touch, while physical buttons
still worked. That points to a retained touch-intercepting SpringBoard window,
but no device logs were supplied and the root cause is not proven.

Prior 0.3 changes: PHPicker video selection; immediate window closure on selection or
cancellation; hotkey toggles any existing overlay closed; empty/result-window
expiry; background cancellable import. Decoder relocated from mediaserverd to a
separate launchd helper. Fixed-size mmap IPC uses nonblocking POSIX record locks,
with independent inodes on helper restart/source changes. Rendering is queued
outside camera callbacks, bounded to one request, with a four-buffer output
pool and a half-second busy timeout. Default 720 long edge and 30 fps. No file
size/duration rejection. Install/upgrade resets this tweak's preferences.

Passed locally: PCM and hotkey C checks, IPC cross-process video/audio payloads,
invalid dimensions/count rejection, locked-slot frame dropping, kernel release
of record locks on process exit, old/new inode isolation; shell syntax and
plist/YAML parsing. These are development checks, not a phone test app.

Not completed: 0.4 Objective-C and Apple SDK compilation/linking, real DEB
packaging, launching the helper on Dopamine, shared mmap/record locks on iOS,
PHPicker and window lifecycle in SpringBoard, private method hooks, corrected
touch behavior, actual video/audio replacement or loop synchronization.
GitHub runner execution for this revision is not claimed. No compiled DEB was
produced in this workspace.

Camera passthrough on startup, underflow, unsupported formats/resolution,
render contention, or timeout is deliberate. This revision must not be treated
as guaranteeing continuously substituted camera content.

Input reference binaries were only statically inspected and are not bundled.

0.4: copy the original live microphone PCM via
CMSampleBufferCopyPCMDataIntoAudioBufferList, then add the decoded video PCM.
Both inputs use unit gain; peaks saturate. The original microphone sample is
not modified. Video underflow preserves microphone PCM. A propagated custom
attachment avoids mixing an already tagged output again when tags are retained
by later pipeline stages; tag propagation through private converters is unverified.

Passed: both-source sum, polarity cancellation, int16 positive/negative
saturation, non-finite inputs, exact microphone preservation for all 65,536
int16 values with silent video, stereo/mono and rate conversion integration,
and video cache underflow/lock-contention microphone continuity.

Not verified: copying microphone PCM from the actual private capture node,
video audio injection in the live app, mixed audio delivery/latency, retention
of sample attachments by private converters, and real-device microphone behavior.
