#ifndef RUNNER_ZEN_CALL_RECORDER_H_
#define RUNNER_ZEN_CALL_RECORDER_H_

#include <flutter_linux/flutter_linux.h>

// Records a call on Linux, like the Windows runner: only what this app
// plays (its own playback streams, the people in the call — never other
// apps or system sounds) mixed with the default microphone, into a WAV file
// (48 kHz, stereo, 16-bit). Through PulseAudio's client library, which
// PipeWire serves too (pipewire-pulse): every playback stream ("sink
// input") of this process is recorded on its own with a monitor stream and
// followed as streams come and go during the call. libpulse is loaded when
// needed (dlopen), so Zen starts without it; then recording is not
// available.
//
// Method channel "zen/recorder" (see call_recorder.dart):
//   available() -> bool            (libpulse can be loaded)
//   start({path}) -> bool          (errors "unavailable", "start_failed")
//   stop() -> String? (the path)
void zen_call_recorder_register(FlPluginRegistry* registry);

#endif  // RUNNER_ZEN_CALL_RECORDER_H_
