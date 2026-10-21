import AVFoundation
import Foundation
import ImageIO

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Films of the "Filmy" section made small enough to travel between friends
/// (`zen/video`, see video_compressor.dart) on iPhone, iPad and Mac; one
/// file for both apps (the Mac project refers to this one). The system's
/// own encoder through AVAssetExportSession: H.264 / AAC in an MP4 within
/// 1280×720, cut to the asked start and end, without metadata and with the
/// index in front. An export session takes a preset, not a bit rate: when
/// the film comes out bigger than the limit it is made again at 960×540,
/// then 640×480, the last time with the size limit as a hard cap.
///
///  - `isAvailable`: true;
///  - `compress` {input, output, startMs, endMs (-1: to the end),
///    maxShortSide, videoBitrate, audioBitrate, maxBytes?} → {durationMs,
///    width, height, bytes}; `progress` {fraction} is called back meanwhile;
///  - `cancel`: the running export fails with "cancelled";
///  - `thumbnail` {input, atMs, maxSide} → JPEG bytes or nil.
final class ZenVideoBridge {
  static func register(with messenger: FlutterBinaryMessenger) {
    shared.attach(messenger)
  }

  private static let shared = ZenVideoBridge()
  private static let defaultMaxBytes: Int64 = 20 * 1024 * 1024

  private var channel: FlutterMethodChannel?
  private var session: AVAssetExportSession?
  private var cancelled = false
  private var poll: Timer?

  private func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/video", binaryMessenger: messenger)
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
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(true)
    case "cancel":
      cancelled = true
      session?.cancelExport()
      result(nil)
    case "compress":
      guard let input = args["input"] as? String, let output = args["output"] as? String else {
        result(FlutterError(code: "failed", message: "input and output are needed", details: nil))
        return
      }
      let startMs = (args["startMs"] as? NSNumber)?.int64Value ?? 0
      let endMs = (args["endMs"] as? NSNumber)?.int64Value ?? -1
      let maxBytes = (args["maxBytes"] as? NSNumber)?.int64Value ?? ZenVideoBridge.defaultMaxBytes
      cancelled = false
      compress(
        input: URL(fileURLWithPath: input),
        output: URL(fileURLWithPath: output),
        startMs: startMs,
        endMs: endMs,
        maxBytes: maxBytes,
        presets: [
          AVAssetExportPreset1280x720, AVAssetExportPreset960x540, AVAssetExportPreset640x480,
        ],
        result: result)
    case "thumbnail":
      guard let input = args["input"] as? String else {
        result(nil)
        return
      }
      let atMs = (args["atMs"] as? NSNumber)?.int64Value ?? 0
      let maxSide = (args["maxSide"] as? NSNumber)?.intValue ?? 480
      DispatchQueue.global(qos: .userInitiated).async {
        let bytes = ZenVideoBridge.thumbnail(
          URL(fileURLWithPath: input), atMs: atMs, maxSide: maxSide)
        DispatchQueue.main.async {
          result(bytes.map { FlutterStandardTypedData(bytes: $0) })
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func compress(
    input: URL,
    output: URL,
    startMs: Int64,
    endMs: Int64,
    maxBytes: Int64,
    presets: [String],
    result: @escaping FlutterResult
  ) {
    let asset = AVURLAsset(url: input)
    let compatible = AVAssetExportSession.exportPresets(compatibleWith: asset)
    guard let preset = presets.first(where: { compatible.contains($0) }),
      let export = AVAssetExportSession(asset: asset, presetName: preset)
    else {
      result(FlutterError(code: "unsupported", message: "no export preset", details: nil))
      return
    }
    try? FileManager.default.removeItem(at: output)
    export.outputURL = output
    export.outputFileType = .mp4
    export.shouldOptimizeForNetworkUse = true
    // Nothing about where, when or on what it was recorded.
    export.metadata = []
    export.metadataItemFilter = AVMetadataItemFilter.forSharing()
    let start = CMTime(value: max(0, startMs), timescale: 1000)
    let end = endMs < 0 ? asset.duration : CMTime(value: endMs, timescale: 1000)
    export.timeRange = CMTimeRange(start: start, end: end)
    let last = presets.count <= 1
    if last {
      export.fileLengthLimit = maxBytes
    }
    session = export
    poll?.invalidate()
    poll = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      self?.channel?.invokeMethod("progress", arguments: ["fraction": Double(export.progress)])
    }
    export.exportAsynchronously { [weak self] in
      DispatchQueue.main.async {
        guard let self = self else {
          return
        }
        self.poll?.invalidate()
        self.poll = nil
        self.session = nil
        if self.cancelled || export.status == .cancelled {
          try? FileManager.default.removeItem(at: output)
          result(FlutterError(code: "cancelled", message: "cancelled", details: nil))
          return
        }
        guard export.status == .completed else {
          try? FileManager.default.removeItem(at: output)
          result(
            FlutterError(
              code: "failed",
              message: export.error?.localizedDescription ?? "export failed",
              details: nil))
          return
        }
        let bytes =
          ((try? FileManager.default.attributesOfItem(atPath: output.path))?[.size]
          as? NSNumber)?.int64Value ?? 0
        if bytes > maxBytes && !last {
          self.compress(
            input: input, output: output, startMs: startMs, endMs: endMs,
            maxBytes: maxBytes, presets: Array(presets.dropFirst()), result: result)
          return
        }
        result(ZenVideoBridge.describe(output, bytes: bytes))
      }
    }
  }

  private static func describe(_ url: URL, bytes: Int64) -> [String: Any] {
    let asset = AVURLAsset(url: url)
    var width = 0
    var height = 0
    if let track = asset.tracks(withMediaType: .video).first {
      let size = track.naturalSize.applying(track.preferredTransform)
      width = Int(abs(size.width).rounded())
      height = Int(abs(size.height).rounded())
    }
    return [
      "durationMs": Int64(CMTimeGetSeconds(asset.duration) * 1000),
      "width": width,
      "height": height,
      "bytes": bytes,
    ]
  }

  private static func thumbnail(_ url: URL, atMs: Int64, maxSide: Int) -> Data? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: maxSide, height: maxSide)
    guard
      let image = try? generator.copyCGImage(
        at: CMTime(value: max(0, atMs), timescale: 1000), actualTime: nil)
    else {
      return nil
    }
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, "public.jpeg" as CFString, 1, nil)
    else {
      return nil
    }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      return nil
    }
    return data as Data
  }
}
