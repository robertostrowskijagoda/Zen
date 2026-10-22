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

#if os(macOS)
  /// The camera of the "Filmy" recorder on a Mac (`zen/camera`, see
  /// film_camera_channel.dart): an AVCaptureSession with the camera and the
  /// microphone; the live picture goes to Flutter as a texture
  /// (AVCaptureVideoDataOutput), the recording to a temporary QuickTime file
  /// (AVCaptureMovieFileOutput, both at once). The film is compressed
  /// afterwards like any other (ZenVideoBridge).
  ///
  ///  - `lenses` → ["front"] (and "back" for a second camera, e.g. an
  ///    external one), or [] without a camera;
  ///  - `open` {lens} → {textureId, width, height};
  ///  - `setTorch`: a Mac has no light; nothing happens;
  ///  - `start`, `stop` → the recording's path, `close`.
  final class ZenCameraBridge: NSObject, FlutterTexture,
    AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate
  {
    static func register(with registrar: FlutterPluginRegistrar) {
      let bridge = ZenCameraBridge(textures: registrar.textures)
      let channel = FlutterMethodChannel(
        name: "zen/camera", binaryMessenger: registrar.messenger)
      channel.setMethodCallHandler { call, result in
        bridge.handle(call, result)
      }
      shared = bridge
    }

    private static var shared: ZenCameraBridge?

    private let textures: FlutterTextureRegistry
    private let queue = DispatchQueue(label: "zen.camera")
    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var movie: AVCaptureMovieFileOutput?
    private var latest: CVPixelBuffer?
    private var textureId: Int64 = 0
    private var stopping: FlutterResult?

    private init(textures: FlutterTextureRegistry) {
      self.textures = textures
      super.init()
    }

    private static func cameras() -> [AVCaptureDevice] {
      var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
      if #available(macOS 14.0, *) {
        types.append(.external)
      } else {
        types.append(.externalUnknown)
      }
      return AVCaptureDevice.DiscoverySession(
        deviceTypes: types, mediaType: .video, position: .unspecified
      ).devices
    }

    private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "lenses":
        let count = ZenCameraBridge.cameras().count
        let names: [String] = Array(["front", "back"].prefix(min(count, 2)))
        result(names)
      case "open":
        let lens = args["lens"] as? String ?? "front"
        AVCaptureDevice.requestAccess(for: .video) { granted in
          AVCaptureDevice.requestAccess(for: .audio) { _ in
            DispatchQueue.main.async {
              guard granted else {
                result(FlutterError(code: "denied", message: "no camera permission", details: nil))
                return
              }
              self.open(lens: lens, result: result)
            }
          }
        }
      case "setTorch":
        result(nil)
      case "start":
        guard let movie = movie, !movie.isRecording else {
          result(FlutterError(code: "failed", message: "camera closed", details: nil))
          return
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
          "zen-film-\(UUID().uuidString).mov")
        movie.startRecording(to: url, recordingDelegate: self)
        result(nil)
      case "stop":
        guard let movie = movie, movie.isRecording else {
          result(FlutterError(code: "failed", message: "not recording", details: nil))
          return
        }
        stopping = result
        movie.stopRecording()
      case "close":
        close()
        result(nil)
      case "luma":
        result(luma())
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    /// The newest picture in shades of grey, at most 640 pixels wide (a QR
    /// scanner reads it): {width, height, bytes}, or nil.
    private func luma() -> [String: Any]? {
      lock.lock()
      let frame = latest
      lock.unlock()
      guard let buffer = frame,
        CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
      else {
        return nil
      }
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      guard let base = CVPixelBufferGetBaseAddress(buffer) else {
        return nil
      }
      let width = CVPixelBufferGetWidth(buffer)
      let height = CVPixelBufferGetHeight(buffer)
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      let step = max(1, (width + 639) / 640)
      let outWidth = width / step
      let outHeight = height / step
      guard outWidth > 0, outHeight > 0 else {
        return nil
      }
      let pixels = base.assumingMemoryBound(to: UInt8.self)
      var gray = [UInt8](repeating: 0, count: outWidth * outHeight)
      for y in 0..<outHeight {
        let row = pixels + (y * step) * stride
        for x in 0..<outWidth {
          let p = row + (x * step) * 4
          // BGRA
          let value = (Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8
          gray[y * outWidth + x] = UInt8(value)
        }
      }
      return [
        "width": outWidth, "height": outHeight,
        "bytes": FlutterStandardTypedData(bytes: Data(gray)),
      ]
    }

    private func open(lens: String, result: @escaping FlutterResult) {
      close()
      let devices = ZenCameraBridge.cameras()
      guard !devices.isEmpty else {
        result(FlutterError(code: "failed", message: "no camera", details: nil))
        return
      }
      let device = lens == "back" && devices.count > 1 ? devices[1] : devices[0]
      let session = AVCaptureSession()
      session.beginConfiguration()
      if session.canSetSessionPreset(.hd1280x720) {
        session.sessionPreset = .hd1280x720
      }
      guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input)
      else {
        result(FlutterError(code: "failed", message: "the camera cannot be opened", details: nil))
        return
      }
      session.addInput(input)
      if let mic = AVCaptureDevice.default(for: .audio),
        let audio = try? AVCaptureDeviceInput(device: mic), session.canAddInput(audio)
      {
        session.addInput(audio)
      }
      let frames = AVCaptureVideoDataOutput()
      frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
      frames.alwaysDiscardsLateVideoFrames = true
      frames.setSampleBufferDelegate(self, queue: queue)
      if session.canAddOutput(frames) {
        session.addOutput(frames)
      }
      let movie = AVCaptureMovieFileOutput()
      if session.canAddOutput(movie) {
        session.addOutput(movie)
      }
      session.commitConfiguration()
      self.session = session
      self.movie = movie
      textureId = textures.register(self)
      let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
      queue.async {
        session.startRunning()
      }
      result(["textureId": textureId, "width": Int(size.width), "height": Int(size.height)])
    }

    private func close() {
      if let movie = movie, movie.isRecording {
        movie.stopRecording()
      }
      if let session = session {
        queue.async {
          session.stopRunning()
        }
      }
      session = nil
      movie = nil
      if textureId != 0 {
        textures.unregisterTexture(textureId)
        textureId = 0
      }
      lock.lock()
      latest = nil
      lock.unlock()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
      lock.lock()
      defer { lock.unlock() }
      guard let frame = latest else {
        return nil
      }
      return Unmanaged.passRetained(frame)
    }

    func captureOutput(
      _ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
      from connection: AVCaptureConnection
    ) {
      guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else {
        return
      }
      lock.lock()
      latest = frame
      lock.unlock()
      DispatchQueue.main.async {
        if self.textureId != 0 {
          self.textures.textureFrameAvailable(self.textureId)
        }
      }
    }

    func fileOutput(
      _ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
      from connections: [AVCaptureConnection], error: Error?
    ) {
      DispatchQueue.main.async {
        guard let result = self.stopping else {
          return
        }
        self.stopping = nil
        // A recording stopped by hand ends "with an error" that still has
        // the whole file (AVErrorRecordingSuccessfullyFinishedKey).
        let finished =
          error == nil
          || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool
            ?? false)
        if finished {
          result(outputFileURL.path)
        } else {
          result(
            FlutterError(
              code: "failed", message: error?.localizedDescription ?? "recording failed",
              details: nil))
        }
      }
    }
  }
#endif

/// Pictures and files on the clipboard, and files dropped on the Mac
/// window (`zen/media_transfer`, see media_transfer.dart):
///  - `read` {textFirst} → [{name, path} | {name, bytes}]: on a Mac, files
///    copied in the Finder first; else a picture: a GIF as it is (what
///    iPhone keyboards copy), PNG or JPEG, any other image as PNG. With
///    textFirst, text on the clipboard gives [] (⌘V pastes the text);
///  - `drop` {paths, x, y} to Dart: files dropped on the Mac window
///    (MainFlutterWindow), in points of the Flutter view from its top left.
final class ZenMediaTransferBridge {
  @discardableResult
  static func register(with messenger: FlutterBinaryMessenger) -> ZenMediaTransferBridge {
    let bridge = ZenMediaTransferBridge()
    let channel = FlutterMethodChannel(name: "zen/media_transfer", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "read" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let args = call.arguments as? [String: Any] ?? [:]
      result(bridge.read(textFirst: args["textFirst"] as? Bool ?? false))
    }
    bridge.channel = channel
    return bridge
  }

  private var channel: FlutterMethodChannel?
  private static let gifType = "com.compuserve.gif"

  func drop(paths: [String], x: Double, y: Double) {
    guard !paths.isEmpty else {
      return
    }
    channel?.invokeMethod("drop", arguments: ["paths": paths, "x": x, "y": y])
  }

  private func picture(_ name: String, _ data: Data) -> [String: Any] {
    return ["name": name, "bytes": FlutterStandardTypedData(bytes: data)]
  }

  #if os(iOS)
    private func read(textFirst: Bool) -> [[String: Any]] {
      let board = UIPasteboard.general
      if textFirst && board.hasStrings {
        return []
      }
      if let data = board.data(forPasteboardType: ZenMediaTransferBridge.gifType) {
        return [picture("schowek.gif", data)]
      }
      if let data = board.data(forPasteboardType: "public.png") {
        return [picture("schowek.png", data)]
      }
      if let data = board.data(forPasteboardType: "public.jpeg") {
        return [picture("schowek.jpg", data)]
      }
      if let image = board.image, let data = image.pngData() {
        return [picture("schowek.png", data)]
      }
      return []
    }
  #else
    private func read(textFirst: Bool) -> [[String: Any]] {
      let board = NSPasteboard.general
      let paths = ZenMediaTransferBridge.filePaths(board)
      if !paths.isEmpty {
        return paths.map { ["path": $0] }
      }
      if textFirst && board.availableType(from: [.string]) != nil {
        return []
      }
      if let data = board.data(forType: NSPasteboard.PasteboardType(ZenMediaTransferBridge.gifType)) {
        return [picture("schowek.gif", data)]
      }
      if let data = board.data(forType: .png) {
        return [picture("schowek.png", data)]
      }
      if let data = board.data(forType: .tiff),
        let image = NSBitmapImageRep(data: data),
        let png = image.representation(using: .png, properties: [:])
      {
        return [picture("schowek.png", png)]
      }
      return []
    }

    /// The files (not folders) on [board].
    static func filePaths(_ board: NSPasteboard) -> [String] {
      let urls =
        board.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      return urls.compactMap { url in
        var folder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &folder),
          !folder.boolValue
        else {
          return nil
        }
        return url.path
      }
    }
  #endif
}
