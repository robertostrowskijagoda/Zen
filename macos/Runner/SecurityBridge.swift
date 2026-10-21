import Cocoa
import CryptoKit
import FlutterMacOS
import LocalAuthentication

/// Screen protection (`zen/secure_window`) and the hardware key vault
/// (`zen/keyvault`) on the Mac, as security_bridge.cpp does on Windows.
/// Dart side: secure_screen.dart and platform_key_vault.dart.
enum SecurityBridge {
  static func register(with messenger: FlutterBinaryMessenger, window: NSWindow) {
    let secureWindow = FlutterMethodChannel(
      name: "zen/secure_window", binaryMessenger: messenger)
    secureWindow.setMethodCallHandler { [weak window] call, result in
      guard call.method == "setSecure" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let window = window else {
        result(false)
        return
      }
      let arguments = call.arguments as? [String: Any]
      let secure = arguments?["secure"] as? Bool ?? false
      // Left out of screenshots, recordings and screen sharing that honour
      // the window's sharing type.
      window.sharingType = secure ? NSWindow.SharingType.none : .readOnly
      result(true)
    }
    let vault = FlutterMethodChannel(name: "zen/keyvault", binaryMessenger: messenger)
    vault.setMethodCallHandler { call, result in
      KeyVault.handle(call, result)
    }
  }
}

/// A P-256 key in the Mac's Secure Enclave that works only after Touch ID
/// with the fingerprints enrolled when it was made. Sealing needs just its
/// public key (an ephemeral key agreement, HKDF-SHA256, AES-GCM); opening
/// needs the enclave key, so the Mac itself asks for the finger. The key
/// never leaves the enclave: its handle, useless on any other Mac, is kept
/// in the app's defaults, and forgetting the handle destroys the key.
private enum KeyVault {
  enum Failure: Error {
    case accessControl
    case noKey
    case badData
  }

  static let handleKey = "zen.keyvault.handle"
  static let info = Data("zen-keyvault-v1".utf8)
  /// An uncompressed P-256 point: the ephemeral key in front of the box.
  static let ephemeralKeyLength = 65

  static func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "available":
      result(isAvailable())
    case "describe":
      result(isAvailable() ? "Secure Enclave" : "brak")
    case "wipe":
      UserDefaults.standard.removeObject(forKey: handleKey)
      result(true)
    case "seal":
      guard let data = (arguments?["data"] as? FlutterStandardTypedData)?.data else {
        result(nil)
        return
      }
      run(result) { try KeyVault.seal(data) }
    case "open":
      guard let data = (arguments?["data"] as? FlutterStandardTypedData)?.data else {
        result(nil)
        return
      }
      let reason = arguments?["reason"] as? String ?? ""
      run(result) { try KeyVault.open(data, reason: reason.isEmpty ? "Zen" : reason) }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func isAvailable() -> Bool {
    return SecureEnclave.isAvailable
      && LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
  }

  /// Runs [work] off the main thread (Touch ID waits for the finger) and
  /// answers on it. Any failure (cancelled, no enclave, new fingerprints)
  /// answers null, as on Windows.
  static func run(_ result: @escaping FlutterResult, _ work: @escaping () throws -> Data) {
    DispatchQueue.global(qos: .userInitiated).async {
      let answer: Any?
      do {
        let bytes = try work()
        answer = FlutterStandardTypedData(bytes: bytes)
      } catch {
        NSLog("Zen key vault: %@", "\(error)" as NSString)
        answer = nil
      }
      DispatchQueue.main.async {
        result(answer)
      }
    }
  }

  /// The enclave key, made on first use.
  static func enclaveKey() throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
    if let handle = UserDefaults.standard.data(forKey: handleKey) {
      return try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: handle)
    }
    guard
      let access = SecAccessControlCreateWithFlags(
        kCFAllocatorDefault, kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        [.privateKeyUsage, .biometryCurrentSet], nil)
    else {
      throw Failure.accessControl
    }
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
    UserDefaults.standard.set(key.dataRepresentation, forKey: handleKey)
    return key
  }

  static func symmetricKey(
    _ shared: SharedSecret, _ ephemeral: P256.KeyAgreement.PublicKey
  ) -> SymmetricKey {
    return shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: ephemeral.x963Representation, sharedInfo: info,
      outputByteCount: 32)
  }

  static func seal(_ secret: Data) throws -> Data {
    let recipient = try enclaveKey().publicKey
    let ephemeral = P256.KeyAgreement.PrivateKey()
    let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
    let box = try AES.GCM.seal(secret, using: symmetricKey(shared, ephemeral.publicKey))
    guard let combined = box.combined else {
      throw Failure.badData
    }
    return ephemeral.publicKey.x963Representation + combined
  }

  static func open(_ sealed: Data, reason: String) throws -> Data {
    guard let handle = UserDefaults.standard.data(forKey: handleKey) else {
      throw Failure.noKey
    }
    guard sealed.count > ephemeralKeyLength else {
      throw Failure.badData
    }
    let context = LAContext()
    context.localizedReason = reason
    let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(
      dataRepresentation: handle, authenticationContext: context)
    let ephemeral = try P256.KeyAgreement.PublicKey(
      x963Representation: sealed.prefix(ephemeralKeyLength))
    // The enclave asks for Touch ID here.
    let shared = try key.sharedSecretFromKeyAgreement(with: ephemeral)
    let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(ephemeralKeyLength))
    return try AES.GCM.open(box, using: symmetricKey(shared, ephemeral))
  }
}
