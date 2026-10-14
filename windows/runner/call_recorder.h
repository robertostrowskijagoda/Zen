#ifndef RUNNER_CALL_RECORDER_H_
#define RUNNER_CALL_RECORDER_H_

#include <flutter/binary_messenger.h>

// Records a call on Windows (§13.2): only what this app plays (the other
// side, through process loopback — never other apps or system sounds) mixed
// with the microphone, into a WAV file.
// flutter_webrtc has no recorder on Windows, so this lives in the runner.
//
// Method channel "zen/recorder":
//   available() -> bool
//   start({path}) -> bool          (throws "start_failed" with a reason)
//   stop() -> String? (the path)
namespace call_recorder {

void Register(flutter::BinaryMessenger* messenger);

}  // namespace call_recorder

#endif  // RUNNER_CALL_RECORDER_H_
