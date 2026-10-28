import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// Files dropped on the window and the clipboard (media_transfer.dart).
  private var mediaTransfer: ZenMediaTransferBridge?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // A phone-sized column, like the Windows runner; the Dart side
    // (desktop_window_bridge.dart) keeps the same sizes.
    self.setContentSize(NSSize(width: 430, height: 880))
    self.contentMinSize = NSSize(width: 390, height: 720)
    // Portrait only: no full-screen space (the green button zooms into a
    // tall column instead, see setFrame below).
    self.collectionBehavior.remove(.fullScreenPrimary)
    self.collectionBehavior.insert(.fullScreenNone)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Screen protection and the Secure Enclave key vault.
    SecurityBridge.register(
      with: flutterViewController.engine.binaryMessenger, window: self)
    // Bluetooth and Multipeer links with friends nearby.
    ZenLocalLinksBridge.register(with: flutterViewController.engine.binaryMessenger)
    // "W pobliżu": a Mac looks around for Zen's nearby advert (it cannot
    // show one: CoreBluetooth shows no manufacturer data).
    ZenNearbyRadioBridge.register(with: flutterViewController.engine.binaryMessenger)
    // Where the device is (the alarm), from Core Location.
    ZenLocationBridge.register(with: flutterViewController.engine.binaryMessenger)
    // Signs of a debugger or injected libraries (device_integrity.dart).
    ZenIntegrityBridge.register(with: flutterViewController.engine.binaryMessenger)
    // Films of the "Filmy" section compressed and trimmed (AVFoundation).
    ZenVideoBridge.register(with: flutterViewController.engine.binaryMessenger)
    // Call recording: what the call plays and the microphone (AAC).
    ZenCallRecorder.register(with: flutterViewController.engine.binaryMessenger)
    // The recorder's own camera (AVCaptureSession, in ZenVideoBridge.swift).
    ZenCameraBridge.register(
      with: flutterViewController.registrar(forPlugin: "ZenCameraBridge"))
    // Files dropped on the window, pictures and files pasted (⌘V).
    mediaTransfer = ZenMediaTransferBridge.register(
      with: flutterViewController.engine.binaryMessenger)
    registerForDraggedTypes([.fileURL])
    // Zen's own files opened from Finder (AppDelegate.swift).
    ZenOpenedFilesBridge.register(
      with: flutterViewController.registrar(forPlugin: "ZenOpenedFilesBridge"))

    super.awakeFromNib()
  }

  /// Width / height at most: the window stays portrait however it is
  /// resized or zoomed.
  private static let maxAspect: CGFloat = 0.8

  private func portrait(_ rect: NSRect) -> NSRect {
    let maxWidth = (rect.height * MainFlutterWindow.maxAspect).rounded(.down)
    guard rect.width > maxWidth else {
      return rect
    }
    var narrowed = rect
    narrowed.size.width = maxWidth
    let current = frame
    if inLiveResize && rect.maxX == current.maxX {
      // The left edge is being dragged: keep the right one.
      narrowed.origin.x = rect.maxX - maxWidth
    } else if !(inLiveResize && rect.minX == current.minX) {
      // Zoomed, snapped or resized by the app: around the centre.
      narrowed.origin.x = rect.midX - maxWidth / 2
    }
    return narrowed
  }

  override func setFrame(_ frameRect: NSRect, display flag: Bool) {
    super.setFrame(portrait(frameRect), display: flag)
  }

  override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
    super.setFrame(portrait(frameRect), display: displayFlag, animate: animateFlag)
  }

  @objc func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return ZenMediaTransferBridge.filePaths(sender.draggingPasteboard).isEmpty ? [] : .copy
  }

  @objc func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    return ZenMediaTransferBridge.filePaths(sender.draggingPasteboard).isEmpty ? [] : .copy
  }

  @objc func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let paths = ZenMediaTransferBridge.filePaths(sender.draggingPasteboard)
    guard !paths.isEmpty, let view = contentView else {
      return false
    }
    // Window coordinates (from the bottom left) to the view's top left.
    let point = view.convert(sender.draggingLocation, from: nil)
    let top = view.isFlipped ? point.y : view.bounds.height - point.y
    mediaTransfer?.drop(paths: paths, x: Double(point.x), y: Double(top))
    return true
  }
}
