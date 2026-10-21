import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:zen/src/core/crypto/hybrid_signature_core.dart';
import 'package:zen/src/features/runtime/yggdrasil_bridge_ffi.dart';

typedef _JsonCall = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

/// The three calls of the bridge (`pq_sign_exports.go`), synchronous.
final class _SigCalls {
  _SigCalls(DynamicLibrary library)
    : publicKey = library.lookupFunction<_JsonCall, _JsonCall>(
        'YggSigPublicKeyJson',
      ),
      sign = library.lookupFunction<_JsonCall, _JsonCall>('YggSigSignJson'),
      verify = library.lookupFunction<_JsonCall, _JsonCall>('YggSigVerifyJson'),
      free = library.lookupFunction<_NativeFree, _DartFree>('YggFreeString');

  final _JsonCall publicKey;
  final _JsonCall sign;
  final _JsonCall verify;
  final _DartFree free;

  _JsonCall byName(String op) => switch (op) {
    'public' => publicKey,
    'sign' => sign,
    _ => verify,
  };

  /// The bridge's JSON answer to [request].
  String call(String op, String request) {
    final Pointer<Utf8> native = request.toNativeUtf8();
    try {
      final Pointer<Utf8> result = byName(op)(native);
      try {
        return result.toDartString();
      } finally {
        free(result);
      }
    } finally {
      malloc.free(native);
    }
  }
}

/// [HybridSigner] of the Go bridge. A signature takes about a millisecond
/// and a check a few tenths on a phone, and the ledger and the pyramid
/// check them by the hundred while syncing: the calls run in a worker
/// isolate of their own, so the UI (and a call's frames) never wait for
/// them. [BridgeHybridSigner.inline] calls on the caller's isolate (tests).
final class BridgeHybridSigner implements HybridSigner {
  BridgeHybridSigner._(this._inline);

  /// Calls [library] directly on the calling isolate.
  BridgeHybridSigner.inline(DynamicLibrary library)
    : _inline = _SigCalls(library);

  /// The bridge this process loads anyway (yggdrasil_bridge_ffi.dart); its
  /// functions are looked up once here, so a missing bridge fails now.
  static BridgeHybridSigner load() {
    _SigCalls(YggdrasilBridgeFfi.openLibrary());
    return BridgeHybridSigner._(null);
  }

  /// The same bridge, called on the calling isolate (`flutter test`: a
  /// worker's answers come only through the real event loop, which a
  /// widget test's fake clock does not run).
  static BridgeHybridSigner loadInline() =>
      BridgeHybridSigner.inline(YggdrasilBridgeFfi.openLibrary());

  final _SigCalls? _inline;
  Future<SendPort>? _worker;
  int _nextId = 0;
  final Map<int, Completer<String>> _waiting = <int, Completer<String>>{};

  Future<Map<String, dynamic>> _call(
    String op,
    Map<String, Object> request,
  ) async {
    final String encoded = jsonEncode(request);
    final _SigCalls? inline = _inline;
    final String answer;
    if (inline != null) {
      answer = inline.call(op, encoded);
    } else {
      final SendPort worker = await (_worker ??= _spawn());
      final int id = _nextId++;
      final Completer<String> done = Completer<String>();
      _waiting[id] = done;
      worker.send(<Object>[id, op, encoded]);
      answer = await done.future;
    }
    final Object? decoded = jsonDecode(answer);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('The bridge signer gave no object.');
    }
    if (decoded['ok'] != true) {
      throw FormatException(
        decoded['error'] as String? ?? 'The bridge signer failed.',
      );
    }
    final Object? data = decoded['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('The bridge signer gave no data.');
    }
    return data;
  }

  Future<SendPort> _spawn() async {
    final ReceivePort replies = ReceivePort('zen-signatures');
    final Completer<SendPort> ready = Completer<SendPort>();
    replies.listen((Object? message) {
      if (message is SendPort) {
        ready.complete(message);
      } else if (message is List && message.length == 2) {
        _waiting.remove(message[0])?.complete(message[1] as String);
      }
    });
    try {
      await Isolate.spawn(
        _serve,
        replies.sendPort,
        debugName: 'zen-signatures',
        errorsAreFatal: false,
      );
    } on Object {
      replies.close();
      _worker = null;
      rethrow;
    }
    return ready.future;
  }

  /// The worker: answers `[id, op, request]` with `[id, answer]`.
  static void _serve(SendPort replies) {
    _SigCalls? opened;
    Object? failure;
    try {
      opened = _SigCalls(YggdrasilBridgeFfi.openLibrary());
    } on Object catch (error) {
      failure = error;
    }
    final _SigCalls? calls = opened;
    final ReceivePort requests = ReceivePort();
    requests.listen((Object? message) {
      final List<Object?> m = message as List<Object?>;
      String answer;
      try {
        if (calls == null) {
          throw StateError('No bridge: $failure');
        }
        answer = calls.call(m[1] as String, m[2] as String);
      } on Object catch (error) {
        answer = jsonEncode(<String, Object>{'ok': false, 'error': '$error'});
      }
      replies.send(<Object?>[m[0], answer]);
    });
    replies.send(requests.sendPort);
  }

  static Uint8List _bytes(Object? value, int length) {
    if (value is! String) {
      throw const FormatException('The bridge signer gave no bytes.');
    }
    final Uint8List bytes = base64.decode(value);
    if (bytes.length != length) {
      throw FormatException('The bridge signer gave ${bytes.length} bytes.');
    }
    return bytes;
  }

  @override
  Future<HybridPublicKey> publicKeyOf(Uint8List seed) async {
    final Map<String, dynamic> data = await _call('public', <String, Object>{
      'seed': base64.encode(seed),
    });
    return HybridPublicKey(
      ed: _bytes(data['ed'], kEd25519PublicKeyBytes),
      pq: _bytes(data['pq'], kMlDsaPublicKeyBytes),
      fingerprint: _bytes(data['fingerprint'], kSigFingerprintBytes),
    );
  }

  @override
  Future<Uint8List> signDigest(
    Uint8List seed,
    Uint8List digest, {
    bool withKey = false,
  }) async {
    final Map<String, dynamic> data = await _call('sign', <String, Object>{
      'seed': base64.encode(seed),
      'digest': base64.encode(digest),
      'withKey': withKey,
    });
    return _bytes(
      data['signature'],
      withKey ? kKeyedHybridSignatureBytes : kHybridSignatureBytes,
    );
  }

  @override
  Future<bool> verifyDigest(
    Uint8List ed,
    Uint8List digest,
    Uint8List signature, {
    Uint8List? pqKey,
  }) async {
    final Map<String, dynamic> data = await _call('verify', <String, Object>{
      'publicKey': base64.encode(ed),
      'digest': base64.encode(digest),
      'signature': base64.encode(signature),
      if (pqKey != null) 'pqKey': base64.encode(pqKey),
    });
    return data['valid'] == true;
  }
}
