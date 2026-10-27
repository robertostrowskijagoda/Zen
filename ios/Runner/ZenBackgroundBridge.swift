import AVFoundation
import BackgroundTasks
import Flutter
import UIKit

/// Time to run while Zen is off the screen (`zen/background`).
///
/// iOS freezes an app a few seconds after it leaves the screen, and Zen has
/// no server to send pushes from, so this is all an iPhone gets
/// (docs/IOS_BACKGROUND.md):
///  - leaving the screen: up to about 30 s more (`beginBackgroundTask`), so
///    what was just sent still reaches the friends' mailboxes;
///  - a background refresh (`BGAppRefreshTask`, about 30 s) whenever iOS
///    decides: a few times a day at best, never after the app was swiped
///    away, in Low Power Mode or with "Background App Refresh" off; and a
///    longer one while the phone charges (`BGProcessingTask`). Dart asks the
///    mailboxes for what they hold then (ios_background.dart);
///  - opt-in ("Odbieraj w tle cały czas"): a silent sound keeps the app
///    running (the `audio` background mode) for as long as it plays.
///
/// Dart calls `configure` {ready, keepAlive} → status and `status` →
/// status. `ready`: the core runs and the app is unlocked; nothing runs in
/// the background otherwise (a locked app cannot store what comes in).
/// This side calls `catchUp` {seconds} → Bool (false: Zen could not check).
/// Everything runs on the main thread.
final class ZenBackgroundBridge {
  static let shared = ZenBackgroundBridge()

  /// Both are listed under BGTaskSchedulerPermittedIdentifiers (Info.plist).
  /// They need not start with the bundle id, which a re-signing changes.
  static let refreshTask = "com.roj.zen.refresh"
  static let processingTask = "com.roj.zen.catchup"

  /// What Dart may use of the ~30 s of a refresh, and of a processing task
  /// (iOS allows minutes there, and ends it early when it needs to).
  private static let refreshSeconds = 25
  private static let processingSeconds = 180

  /// The earliest next refresh; iOS usually waits much longer.
  private static let refreshEvery: TimeInterval = 15 * 60

  /// When iOS last woke Zen and how that went, for the settings page (only
  /// times and a word, nothing about messages).
  private static let lastRunAtKey = "zen.background.lastRunAt"
  private static let lastRunResultKey = "zen.background.lastRunResult"
  private static let runsKey = "zen.background.runs"

  static func register(with messenger: FlutterBinaryMessenger) {
    shared.attach(messenger)
  }

  private var channel: FlutterMethodChannel?
  private var ready = false
  private var keepAliveWanted = false
  private var inBackground = false
  private var finishing: UIBackgroundTaskIdentifier = .invalid
  private let keepAlive = SilentKeepAlive()
  private var observers: [NSObjectProtocol] = []

  private init() {}

  /// From `application(_:didFinishLaunchingWithOptions:)`: iOS takes the
  /// task handlers only until launching ends.
  func start() {
    let scheduler = BGTaskScheduler.shared
    for (identifier, seconds) in [
      (ZenBackgroundBridge.refreshTask, ZenBackgroundBridge.refreshSeconds),
      (ZenBackgroundBridge.processingTask, ZenBackgroundBridge.processingSeconds),
    ] {
      let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) {
        task in
        self.run(task, seconds: seconds)
      }
      if !registered {
        NSLog("Zen: the background task \(identifier) was not registered")
      }
    }
    let center = NotificationCenter.default
    // The scene notifications and the app ones both come; handling either
    // is idempotent.
    for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          self?.enteredBackground()
        })
    }
    for name in [
      UIScene.willEnterForegroundNotification, UIApplication.willEnterForegroundNotification,
      UIApplication.didBecomeActiveNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          self?.enteredForeground()
        })
    }
  }

  private func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/background", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "configure":
      let arguments = call.arguments as? [String: Any]
      ready = arguments?["ready"] as? Bool ?? false
      keepAliveWanted = arguments?["keepAlive"] as? Bool ?? false
      if !ready {
        // Locked (or the core stopped): let iOS freeze the app now.
        endFinishing()
      }
      updateKeepAlive()
      result(status())
    case "status":
      result(status())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Leaving and coming back

  private func enteredBackground() {
    guard !inBackground else {
      return
    }
    inBackground = true
    schedule()
    beginFinishing()
    updateKeepAlive()
  }

  private func enteredForeground() {
    guard inBackground else {
      return
    }
    inBackground = false
    endFinishing()
    updateKeepAlive()
  }

  /// The ~30 s iOS still gives an app that just left the screen: a message
  /// sent a moment ago gets its mailbox copies (a few seconds later).
  private func beginFinishing() {
    guard ready, finishing == .invalid else {
      return
    }
    finishing = UIApplication.shared.beginBackgroundTask(withName: "zen.finish") {
      [weak self] in
      self?.endFinishing()
    }
  }

  private func endFinishing() {
    guard finishing != .invalid else {
      return
    }
    UIApplication.shared.endBackgroundTask(finishing)
    finishing = .invalid
  }

  private func updateKeepAlive() {
    if ready && keepAliveWanted && inBackground {
      keepAlive.start()
    } else {
      keepAlive.stop()
    }
  }

  // MARK: Background tasks

  /// Asks for the next refresh and the next charging catch-up; a new request
  /// replaces the one waiting.
  private func schedule() {
    let refresh = BGAppRefreshTaskRequest(identifier: ZenBackgroundBridge.refreshTask)
    refresh.earliestBeginDate = Date(timeIntervalSinceNow: ZenBackgroundBridge.refreshEvery)
    let processing = BGProcessingTaskRequest(identifier: ZenBackgroundBridge.processingTask)
    processing.requiresNetworkConnectivity = true
    processing.requiresExternalPower = true
    for request in [refresh, processing] as [BGTaskRequest] {
      do {
        try BGTaskScheduler.shared.submit(request)
      } catch {
        // The simulator, "Background App Refresh" off, or too many requests.
        NSLog("Zen: \(request.identifier) not scheduled: \(error.localizedDescription)")
      }
    }
  }

  private func run(_ task: BGTask, seconds: Int) {
    schedule()
    // iOS may launch Zen from scratch for a task: then no scene, no Flutter
    // and no Dart run, and there is nothing to do.
    guard ready, let channel = channel else {
      remember("notReady")
      task.setTaskCompleted(success: false)
      return
    }
    var done = false
    let finish: (String, Bool) -> Void = { [weak self] outcome, success in
      guard !done else {
        return
      }
      done = true
      self?.remember(outcome)
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = {
      DispatchQueue.main.async { finish("expired", false) }
    }
    channel.invokeMethod("catchUp", arguments: ["seconds": seconds]) { result in
      let checked = (result as? Bool) ?? false
      finish(checked ? "done" : "skipped", checked)
    }
  }

  private func remember(_ outcome: String) {
    let defaults = UserDefaults.standard
    defaults.set(Date().timeIntervalSince1970 * 1000, forKey: ZenBackgroundBridge.lastRunAtKey)
    defaults.set(outcome, forKey: ZenBackgroundBridge.lastRunResultKey)
    defaults.set(defaults.integer(forKey: ZenBackgroundBridge.runsKey) + 1, forKey: ZenBackgroundBridge.runsKey)
  }

  private func status() -> [String: Any] {
    let refresh: String
    switch UIApplication.shared.backgroundRefreshStatus {
    case .available:
      refresh = "available"
    case .denied:
      refresh = "denied"
    case .restricted:
      refresh = "restricted"
    @unknown default:
      refresh = "unknown"
    }
    let defaults = UserDefaults.standard
    return [
      "refresh": refresh,
      "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "keepAlive": keepAlive.isPlaying,
      "lastRunAt": Int(defaults.double(forKey: ZenBackgroundBridge.lastRunAtKey)),
      "lastRunResult": defaults.string(forKey: ZenBackgroundBridge.lastRunResultKey) ?? "",
      "runs": defaults.integer(forKey: ZenBackgroundBridge.runsKey),
    ]
  }
}

/// The opt-in keep-alive: a looping, silent sound in a session that mixes
/// with other apps' audio. iOS keeps an app that plays sound running in the
/// background; a phone call, Siri or an alarm interrupts it, and it starts
/// again when they end. A Zen call or a recording holds the session itself
/// (and keeps the app running by itself): the session is left alone then,
/// changing its category would cut the microphone.
final class SilentKeepAlive {
  private var player: AVAudioPlayer?
  private var wanted = false

  /// The session as it was before this took it, given back on [stop].
  private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
  private var observers: [NSObjectProtocol] = []

  var isPlaying: Bool { player?.isPlaying == true }

  init() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else {
          return
        }
        self?.resume()
      })
    observers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // Every player is gone with the media services.
        self?.player = nil
        self?.previous = nil
        self?.resume()
      })
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  func start() {
    wanted = true
    resume()
  }

  func stop() {
    guard wanted || player != nil else {
      return
    }
    wanted = false
    player?.stop()
    player = nil
    let session = AVAudioSession.sharedInstance()
    // Only a session still set the way this left it is given back.
    guard let previous = previous, session.category == .playback else {
      self.previous = nil
      return
    }
    self.previous = nil
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      try session.setCategory(previous.0, mode: previous.1, options: previous.2)
    } catch {
      NSLog("Zen: the audio session was not given back: \(error.localizedDescription)")
    }
  }

  private func resume() {
    guard wanted, !isPlaying else {
      return
    }
    let session = AVAudioSession.sharedInstance()
    if session.category == .playAndRecord || session.category == .record {
      return
    }
    do {
      if previous == nil {
        previous = (session.category, session.mode, session.categoryOptions)
      }
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      let player = try self.player ?? AVAudioPlayer(data: SilentKeepAlive.silence)
      player.numberOfLoops = -1
      player.play()
      self.player = player
    } catch {
      NSLog("Zen: the background sound did not start: \(error.localizedDescription)")
    }
  }

  /// One second of silence: 8 kHz, mono, 16-bit PCM in a WAV file.
  private static let silence: Data = {
    let rate: UInt32 = 8000
    let bytes = rate * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(rate)
    append(rate * 2)  // bytes per second
    append(UInt16(2))  // bytes per frame
    append(UInt16(16))  // bits per sample
    data.append(contentsOf: Array("data".utf8))
    append(bytes)
    data.append(Data(count: Int(bytes)))
    return data
  }()
}
