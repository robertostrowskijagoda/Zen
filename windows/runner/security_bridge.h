#ifndef RUNNER_SECURITY_BRIDGE_H_
#define RUNNER_SECURITY_BRIDGE_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

#include <functional>

// Security channels on Windows:
//   "zen/secure_window"  setSecure({secure}) -> bool
//       WDA_EXCLUDEFROMCAPTURE: the window is left out of screenshots,
//       recordings and screen sharing (Windows 10 2004+; older: black).
//   "zen/keyvault"  available / describe / seal({data}) / open({data}) / wipe
//       The app's master key wrapped by an RSA key kept in the TPM
//       (Microsoft Platform Crypto Provider). Without a TPM there is no
//       biometric unlock (no DPAPI fallback). Windows Hello is asked on the
//       Dart side first, and only when the person turned biometric unlock
//       on; the TPM key itself has no UI policy (see security_bridge.cpp).
namespace security_bridge {

void Register(flutter::BinaryMessenger* messenger,
              std::function<HWND()> window);

}  // namespace security_bridge

#endif  // RUNNER_SECURITY_BRIDGE_H_
