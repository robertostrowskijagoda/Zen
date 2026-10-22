import AVFoundation
import Foundation

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Call recording on iPhone, iPad and Mac (`zen/recorder`, see
/// call_recorder.dart); one file for both apps (the Mac project refers to
/// this one). What the call plays — everyone else, already mixed by WebRTC
/// — and the own microphone, mixed into an AAC file (`.m4a`, mono, 48 kHz).
///
/// The sound comes from flutter_webrtc's own audio processing hooks
/// (`AudioManager.sharedInstance`, its `renderPreProcessingAdapter` for what
/// is played and `capturePostProcessingAdapter` for the microphone after
/// echo cancelling), so it covers 1:1 and group calls, with or without
/// video, and people joining and leaving, and holds nothing of other apps
/// or of the device's other sounds. The audio session is left alone: the
/// call keeps its route and settings. The hooks are found at run time (the
/// runner does not build against the plugin): where they are missing,
/// `available` is false and `start` fails with `unavailable`.
///
///  - `available` → bool;
///  - `start` {path} → true; errors `unavailable`, `start_failed`;
///  - `stop` → the path, or nil when nothing ran.
final class ZenCallRecorder {
  static func register(with messenger: FlutterBinaryMessenger) {
    shared.attach(messenger)
  }

  /// The file's sample rate; everything is brought to it.
  static let rate = 48_000.0
  /// How far the writing stays behind the clock, so that a source that is
  /// merely late still lands in its place.
  static let latency = 0.2

  private static let shared = ZenCallRecorder()

  private var channel: FlutterMethodChannel?
  private var session: ZenCallRecording?

  private func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/recorder", binaryMessenger: messenger)
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
    case "available":
      result(ZenWebRtcAudioTaps.find() != nil)
    case "start":
      let args = call.arguments as? [String: Any] ?? [:]
      guard let path = args["path"] as? String, !path.isEmpty else {
        result(FlutterError(code: "bad_args", message: "path is required", details: nil))
        return
      }
      if session != nil {
        result(FlutterError(code: "start_failed", message: "already recording", details: nil))
        return
      }
      guard let taps = ZenWebRtcAudioTaps.find() else {
        result(
          FlutterError(
            code: "unavailable", message: "flutter_webrtc offers no audio hooks here",
            details: nil))
        return
      }
      do {
        let recording = try ZenCallRecording(path: path, taps: taps)
        recording.start()
        session = recording
        result(true)
      } catch {
        result(
          FlutterError(
            code: "start_failed", message: error.localizedDescription, details: nil))
      }
    case "stop":
      guard let recording = session else {
        result(nil)
        return
      }
      session = nil
      result(recording.finish())
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// flutter_webrtc's audio processing adapters, looked up through the
/// Objective-C runtime: `+[AudioManager sharedInstance]`, its
/// `renderPreProcessingAdapter` and `capturePostProcessingAdapter`, each
/// with `addAudioRenderer:` / `removeAudioRenderer:`. An added renderer gets
/// `renderPCMBuffer:` for every 10 ms of sound (AudioProcessingAdapter.m).
struct ZenWebRtcAudioTaps {
  /// What the call plays: all remote audio, mixed, before it is played.
  let call: NSObject
  /// The microphone, after echo cancelling and noise suppression.
  let microphone: NSObject

  private static let add = NSSelectorFromString("addAudioRenderer:")
  private static let remove = NSSelectorFromString("removeAudioRenderer:")

  static func find() -> ZenWebRtcAudioTaps? {
    guard let managerClass: AnyClass = NSClassFromString("AudioManager") else {
      return nil
    }
    let sharedInstance = NSSelectorFromString("sharedInstance")
    guard let method = class_getClassMethod(managerClass, sharedInstance) else {
      return nil
    }
    typealias Getter = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
    let getter = unsafeBitCast(method_getImplementation(method), to: Getter.self)
    guard
      let manager = getter(managerClass, sharedInstance)?.takeUnretainedValue() as? NSObject,
      let call = adapter(of: manager, named: "renderPreProcessingAdapter"),
      let microphone = adapter(of: manager, named: "capturePostProcessingAdapter")
    else {
      return nil
    }
    return ZenWebRtcAudioTaps(call: call, microphone: microphone)
  }

  private static func adapter(of manager: NSObject, named name: String) -> NSObject? {
    guard manager.responds(to: NSSelectorFromString(name)),
      let adapter = manager.value(forKey: name) as? NSObject,
      adapter.responds(to: add), adapter.responds(to: remove)
    else {
      return nil
    }
    return adapter
  }

  func attach(call callTap: ZenAudioTap, microphone microphoneTap: ZenAudioTap) {
    _ = call.perform(ZenWebRtcAudioTaps.add, with: callTap)
    _ = microphone.perform(ZenWebRtcAudioTaps.add, with: microphoneTap)
  }

  func detach(call callTap: ZenAudioTap, microphone microphoneTap: ZenAudioTap) {
    _ = call.perform(ZenWebRtcAudioTaps.remove, with: callTap)
    _ = microphone.perform(ZenWebRtcAudioTaps.remove, with: microphoneTap)
  }
}

/// Takes the adapter's buffers (on the audio thread, 10 ms of 16-bit sound,
/// one buffer per channel) and hands them to the mix as mono 48 kHz. Kept
/// short: it runs while WebRTC waits.
final class ZenAudioTap: NSObject {
  private let mix: ZenCallMix
  private let source: Int
  private var resampler = ZenResampler()

  init(mix: ZenCallMix, source: Int) {
    self.mix = mix
    self.source = source
    super.init()
  }

  @objc(renderPCMBuffer:)
  func renderPCMBuffer(_ buffer: AVAudioPCMBuffer?) {
    guard let buffer = buffer else {
      return
    }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    let rate = buffer.format.sampleRate
    guard frames > 0, channels > 0, rate > 0 else {
      return
    }
    let interleaved = buffer.format.isInterleaved
    let stride = buffer.stride
    var mono = [Float](repeating: 0, count: frames)
    if let data = buffer.int16ChannelData {
      for c in 0..<channels {
        let samples = interleaved ? data[0] : data[c]
        let offset = interleaved ? c : 0
        for i in 0..<frames {
          mono[i] += Float(samples[i * stride + offset])
        }
      }
    } else if let data = buffer.floatChannelData {
      for c in 0..<channels {
        let samples = interleaved ? data[0] : data[c]
        let offset = interleaved ? c : 0
        for i in 0..<frames {
          mono[i] += samples[i * stride + offset] * 32767
        }
      }
    } else {
      return
    }
    if channels > 1 {
      let scale = 1 / Float(channels)
      for i in 0..<frames {
        mono[i] *= scale
      }
    }
    mix.push(resampler.resample(mono, from: rate), to: source)
  }
}

/// Linear resampling to 48 kHz, continuous across buffers.
struct ZenResampler {
  /// The last sample of the previous buffer.
  private var previous: Float = 0
  /// Where the next output sample lies, in input samples after `previous`.
  private var position = 0.0

  mutating func resample(_ input: [Float], from rate: Double) -> [Int16] {
    guard let last = input.last else {
      return []
    }
    defer { previous = last }
    if rate == ZenCallRecorder.rate {
      position = 0
      return input.map(ZenResampler.sample)
    }
    let step = rate / ZenCallRecorder.rate
    let count = Double(input.count)
    var out: [Int16] = []
    out.reserveCapacity(Int(count / step) + 2)
    var at = position
    while at < count {
      let i = Int(at)
      let fraction = Float(at - Double(i))
      let a = i == 0 ? previous : input[i - 1]
      let b = input[i]
      out.append(ZenResampler.sample(a + (b - a) * fraction))
      at += step
    }
    position = at - count
    return out
  }

  static func sample(_ value: Float) -> Int16 {
    if value.isNaN {
      return 0
    }
    return Int16(max(-32768, min(32767, value.rounded())))
  }
}

/// The call and the microphone side by side until written. Each source
/// keeps at most half a second waiting (older is dropped, so they never
/// drift apart); one that delivers nothing (a muted microphone) adds
/// silence.
final class ZenCallMix {
  static let call = 0
  static let microphone = 1

  private let lock = NSLock()
  private var queues: [[Int16]] = [[], []]
  private let maxBuffered = Int(ZenCallRecorder.rate) / 2

  func push(_ samples: [Int16], to source: Int) {
    if samples.isEmpty {
      return
    }
    lock.lock()
    defer { lock.unlock() }
    queues[source].append(contentsOf: samples)
    let extra = queues[source].count - maxBuffered
    if extra > 0 {
      queues[source].removeFirst(extra)
    }
  }

  /// The next [count] samples of the mix.
  func take(_ count: Int) -> [Int16] {
    var mixed = [Int32](repeating: 0, count: count)
    lock.lock()
    for s in 0..<queues.count {
      let n = min(count, queues[s].count)
      for i in 0..<n {
        mixed[i] += Int32(queues[s][i])
      }
      queues[s].removeFirst(n)
    }
    lock.unlock()
    return mixed.map { Int16(clamping: $0) }
  }
}

/// One recording: the taps feed the mix, a timer writes it to the file at
/// the pace of the clock (silence belongs in the file too).
final class ZenCallRecording {
  private let path: String
  private let taps: ZenWebRtcAudioTaps
  private let mix: ZenCallMix
  private let callTap: ZenAudioTap
  private let microphoneTap: ZenAudioTap
  private let queue = DispatchQueue(label: "zen.call-recorder")
  private var file: AVAudioFile?
  private var timer: DispatchSourceTimer?
  private var begin: UInt64 = 0
  private var written = 0
  private var failed = false

  init(path: String, taps: ZenWebRtcAudioTaps) throws {
    self.path = path
    self.taps = taps
    let mix = ZenCallMix()
    self.mix = mix
    callTap = ZenAudioTap(mix: mix, source: ZenCallMix.call)
    microphoneTap = ZenAudioTap(mix: mix, source: ZenCallMix.microphone)
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)
    let settings: [String: Any] = [
      AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
      AVSampleRateKey: ZenCallRecorder.rate,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 64_000,
    ]
    file = try AVAudioFile(
      forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: false)
  }

  func start() {
    begin = DispatchTime.now().uptimeNanoseconds
    taps.attach(call: callTap, microphone: microphoneTap)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
    timer.setEventHandler { [weak self] in
      self?.writeDue(last: false)
    }
    timer.resume()
    self.timer = timer
  }

  /// Stops the taps, writes what is left and closes the file.
  func finish() -> String {
    taps.detach(call: callTap, microphone: microphoneTap)
    queue.sync {
      timer?.cancel()
      timer = nil
      writeDue(last: true)
      // Releasing the file finishes it (the AAC encoder and the index).
      file = nil
    }
    return path
  }

  /// On [queue]: writes the mix up to now (less the latency while running).
  private func writeDue(last: Bool) {
    guard let file = file else {
      return
    }
    let now = DispatchTime.now().uptimeNanoseconds
    let seconds = Double(now &- begin) / 1_000_000_000
    let behind = last ? 0 : ZenCallRecorder.latency
    let due = Int(max(0, seconds - behind) * ZenCallRecorder.rate)
    var left = due - written
    while left > 0 {
      let n = min(left, Int(ZenCallRecorder.rate))
      let samples = mix.take(n)
      written += n
      left -= n
      guard
        let buffer = AVAudioPCMBuffer(
          pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)),
        let channel = buffer.int16ChannelData?[0]
      else {
        return
      }
      for i in 0..<n {
        channel[i] = samples[i]
      }
      buffer.frameLength = AVAudioFrameCount(n)
      do {
        try file.write(from: buffer)
      } catch {
        if !failed {
          failed = true
          NSLog("Zen: writing the call recording failed: \(error.localizedDescription)")
        }
      }
    }
  }
}
