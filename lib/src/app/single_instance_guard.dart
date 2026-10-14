import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Cross-desktop single-instance lock.
///
/// The runtime node binds a fixed TLS peering port (and multicast sockets), so
/// a second copy of Zen on the same machine cannot start its network at all —
/// it just silently ends up offline. The guard makes that impossible: the first
/// process claims a loopback port, every later process finds it taken, asks the
/// running instance to show its window and exits.
///
/// The lock is loopback-only (never reachable from the network) and every
/// exchange is guarded by a handshake so an unrelated program sitting on the
/// same port cannot be mistaken for a Zen instance — and vice versa.
abstract final class ZenSingleInstance {
  /// Fixed loopback port for the lock. Not a network service: bound to
  /// 127.0.0.1 only.
  static const int lockPort = 47821;

  static const String _hello = 'ZEN-SINGLE-INSTANCE/1';
  static const String _activate = 'ACTIVATE';
  static const String _ack = 'ACK';

  static const Duration _handshakeTimeout = Duration(seconds: 2);

  static ServerSocket? _server;
  static StreamSubscription<Socket>? _subscription;
  static Future<void> Function()? _onActivateRequested;

  /// True on the platforms where the lock applies (desktop only — Android and
  /// iOS already guarantee a single process per app).
  static bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  /// Registers what should happen when another launch asks this instance to
  /// come to the front. Safe to call before or after [acquire].
  static void setActivationHandler(Future<void> Function()? handler) {
    _onActivateRequested = handler;
  }

  /// Tries to become the one and only instance.
  ///
  /// Returns `true` when this process owns the lock (or the platform has no
  /// need for one). Returns `false` when another Zen instance is already
  /// running — the caller should quit immediately.
  ///
  /// [port] exists for tests; production always uses [lockPort].
  static Future<bool> acquire({int port = lockPort}) async {
    if (!isSupported || _server != null) {
      return true;
    }
    try {
      final ServerSocket server = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      _server = server;
      _subscription = server.listen(
        _handleConnection,
        onError: (Object error, StackTrace stackTrace) {
          logZenError('Single instance lock listener error', error, stackTrace);
        },
        cancelOnError: false,
      );
      return true;
    } on SocketException catch (error, stackTrace) {
      logZenError(
        'Single instance lock port is busy, probing the owner',
        error,
        stackTrace,
      );
    }
    // The port is taken. Probing the owner.
    final bool ownedByZen = await _requestActivationFromRunningInstance(port);
    if (!ownedByZen && Platform.isWindows && port == lockPort) {
      // The port was busy, but whatever was on the port did NOT answer the Zen handshake.
      // Clean up any unresponsive zombie processes and retry binding.
      _cleanupZombieProcesses();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      try {
        final ServerSocket server = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        _server = server;
        _subscription = server.listen(
          _handleConnection,
          onError: (Object error, StackTrace stackTrace) {
            logZenError(
              'Single instance lock listener error',
              error,
              stackTrace,
            );
          },
          cancelOnError: false,
        );
        return true;
      } catch (retryError, retryStack) {
        logZenError(
          'Retry binding single instance port failed',
          retryError,
          retryStack,
        );
      }
    }
    return !ownedByZen;
  }

  /// Releases the lock. Called on shutdown; also used by tests.
  static Future<void> release() async {
    final StreamSubscription<Socket>? subscription = _subscription;
    final ServerSocket? server = _server;
    _subscription = null;
    _server = null;
    try {
      await subscription?.cancel();
      await server?.close();
    } catch (error, stackTrace) {
      logZenError('Releasing single instance lock failed', error, stackTrace);
    }
  }

  /// Reads a single handshake line, or `null` when the peer says nothing —
  /// a hung-up connection is normal here, not an error worth logging.
  static Future<String?> _readHandshakeLine(Socket socket) async {
    final List<String> lines = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .take(1)
        .toList()
        .timeout(_handshakeTimeout, onTimeout: () => const <String>[]);
    return lines.isEmpty ? null : lines.first;
  }

  static Future<void> _handleConnection(Socket socket) async {
    try {
      final String? request = await _readHandshakeLine(socket);
      if (request == null || request.trim() != '$_hello $_activate') {
        return;
      }
      socket.write('$_hello $_ack\n');
      await socket.flush();
      final Future<void> Function()? handler = _onActivateRequested;
      if (handler != null) {
        await handler();
      }
    } catch (error, stackTrace) {
      logZenError(
        'Handling single instance activation request failed',
        error,
        stackTrace,
      );
    } finally {
      try {
        await socket.close();
      } catch (_) {
        // The peer may already be gone; nothing to clean up.
      }
      socket.destroy();
    }
  }

  static Future<bool> _requestActivationFromRunningInstance(int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: _handshakeTimeout,
      );
      socket.write('$_hello $_activate\n');
      await socket.flush();
      final String? response = await _readHandshakeLine(socket);
      final bool acknowledged = response?.trim() == '$_hello $_ack';
      if (!acknowledged) {
        return false;
      }
      if (Platform.isWindows) {
        _grantForegroundPermission();
        final bool restored = _bringExistingWindowToForeground();
        if (!restored) {
          logZenWarning(
            'Running instance acknowledged activation, but has no valid window. Treating as zombie.',
          );
          return false;
        }
      }
      return true;
    } catch (error, stackTrace) {
      logZenError('Probing the running Zen instance failed', error, stackTrace);
      return false;
    } finally {
      socket?.destroy();
    }
  }
}

void _grantForegroundPermission() {
  if (!Platform.isWindows) return;
  try {
    final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
    final int Function(int) allowSetForegroundWindow = user32
        .lookupFunction<Int32 Function(Uint32), int Function(int)>(
          'AllowSetForegroundWindow',
        );
    allowSetForegroundWindow(-1);
  } catch (e) {
    debugPrint('[ZEN] AllowSetForegroundWindow error: $e');
  }
}

bool _bringExistingWindowToForeground() {
  if (!Platform.isWindows) return false;
  try {
    final DynamicLibrary user32 = DynamicLibrary.open('user32.dll');
    final int Function(Pointer<Utf16>, Pointer<Utf16>) findWindow = user32
        .lookupFunction<
          IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
          int Function(Pointer<Utf16>, Pointer<Utf16>)
        >('FindWindowW');
    final int Function(int, int) showWindow = user32
        .lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
          'ShowWindow',
        );
    final int Function(int) setForegroundWindow = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'SetForegroundWindow',
        );
    final int Function(int) bringWindowToTop = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
          'BringWindowToTop',
        );
    final int Function(int) isWindow = user32
        .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');

    final Pointer<Utf16> clsPtr = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final Pointer<Utf16> titlePtr = 'Zen'.toNativeUtf16();
    try {
      int hwnd = findWindow(clsPtr, titlePtr);
      if (hwnd == 0) {
        hwnd = findWindow(nullptr, titlePtr);
      }
      if (hwnd == 0) {
        hwnd = findWindow(clsPtr, nullptr);
      }
      if (hwnd != 0 && isWindow(hwnd) != 0) {
        showWindow(hwnd, 9); // SW_RESTORE
        showWindow(hwnd, 5); // SW_SHOW
        bringWindowToTop(hwnd);
        setForegroundWindow(hwnd);
        return true;
      }
    } finally {
      calloc.free(clsPtr);
      calloc.free(titlePtr);
    }
  } catch (e) {
    debugPrint('[ZEN] _bringExistingWindowToForeground error: $e');
  }
  return false;
}

void _cleanupZombieProcesses() {
  if (!Platform.isWindows) return;
  try {
    Process.runSync('taskkill', <String>[
      '/F',
      '/FI',
      'PID ne $pid',
      '/IM',
      'zen.exe',
    ]);
  } catch (e) {
    debugPrint('[ZEN] Cleanup zombie processes error: $e');
  }
}
