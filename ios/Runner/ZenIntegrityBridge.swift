import Foundation
import MachO

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Signs of a modified device or of someone inside this very process
/// (`zen/integrity`, `check`), on iPhone, iPad and Mac; one file for both
/// apps (the Mac project refers to this one). The answer has the shape of
/// ZenSecurityBridge.kt's, read by device_integrity.dart:
///
///  - a debugger attached (`P_TRACED`), libraries injected through
///    `DYLD_INSERT_LIBRARIES`, Frida or a hooking framework (Substrate,
///    libhooker, ElleKit…) among the loaded images: `tampered` — the app
///    then also refuses payments and the pyramid's power key;
///  - a jailbreak (iPhone): `rooted`, a warning only;
///  - the simulator: `emulator`, a hint only.
enum ZenIntegrityBridge {
  private static var channel: FlutterMethodChannel?

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/integrity", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      if call.method == "check" {
        result(check())
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
    self.channel = channel
  }

  private static let fridaMarks = ["frida", "gum-js-loop", "linjector"]

  private static let hookMarks = [
    "substrate", "libhooker", "substitute", "tweakinject", "cycript", "ellekit",
    "sslkillswitch", "libblackjack", "pspawn_payload",
  ]

  private static let jailbreakPaths = [
    "/Applications/Cydia.app", "/Applications/Sileo.app", "/Applications/Zebra.app",
    "/var/jb", "/usr/sbin/sshd", "/etc/apt", "/private/var/lib/apt",
    "/usr/lib/libjailbreak.dylib", "/Library/MobileSubstrate/MobileSubstrate.dylib",
  ]

  static func check() -> [String: Any] {
    var reasons: [String] = []
    var tamper: [String] = []
    if debuggerAttached() {
      tamper.append("debugger")
    }
    if let inserted = getenv("DYLD_INSERT_LIBRARIES"), strlen(inserted) > 0 {
      tamper.append("injected")
    }
    let images = loadedImages()
    if images.contains(where: { name in fridaMarks.contains { name.contains($0) } }) {
      tamper.append("frida-loaded")
    }
    if images.contains(where: { name in hookMarks.contains { name.contains($0) } }) {
      tamper.append("hooks")
    }
    #if os(iOS)
      if jailbreakPaths.contains(where: { FileManager.default.fileExists(atPath: $0) }) {
        reasons.append("jailbreak")
      }
    #endif
    #if targetEnvironment(simulator)
      let emulator = true
    #else
      let emulator = false
    #endif
    let rooted = !reasons.isEmpty
    if emulator {
      reasons.append("emulator")
    }
    reasons.append(contentsOf: tamper)
    return [
      "rooted": rooted,
      "reasons": reasons,
      "debuggable": false,
      "tampered": !tamper.isEmpty,
      "emulator": emulator,
    ]
  }

  /// Whether a debugger traces this process (the kernel's `P_TRACED`).
  private static func debuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    let status = name.withUnsafeMutableBufferPointer { buffer in
      sysctl(buffer.baseAddress, 4, &info, &size, nil, 0)
    }
    return status == 0 && (info.kp_proc.p_flag & P_TRACED) != 0
  }

  /// The names of the images loaded in this process, lower-case.
  private static func loadedImages() -> [String] {
    var names: [String] = []
    for index in 0..<_dyld_image_count() {
      if let name = _dyld_get_image_name(index) {
        names.append(String(cString: name).lowercased())
      }
    }
    return names
  }
}
