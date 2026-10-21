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
      // The port was busy, but whatever was on the port did NOT complete
      // the Zen handshake (or answered without a window). Only hung copies
      // of this very executable run by this user are ended: never
      // somebody else's process that happens to share the name.
      await _cleanupZombieProcesses();
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
    if (!ownedByZen) {
      logZenWarning(
        'Single instance lock port is held by something that is not a '
        'running Zen of this user; starting without the single-instance '
        'guarantee',
      );
    }
    return !ownedByZen;
  }

  static const String _listingScript = r'''
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
function Get-ZenOwner($p) {
  $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner
  if ($o -and $o.ReturnValue -eq 0 -and $o.User) { return "$($o.Domain)\$($o.User)" }
  return ''
}
$me = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
"ME|$(Get-ZenOwner $me)"
Get-CimInstance Win32_Process -Filter "Name='@EXE@'" | ForEach-Object {
  "$($_.ProcessId)|$(Get-ZenOwner $_)|$($_.ExecutablePath)"
}
''';

  /// The PowerShell script that lists running copies of [exeName] for
  /// [zombiePids]: first `ME|<domain>\<user>` (the owner of the script's own
  /// process, i.e. this user), then `<pid>|<domain>\<user>|<path>` per
  /// process. An owner or path Windows will not tell (another user's
  /// process without elevation) comes out empty. `null` for a name that
  /// does not look like a plain file name (nothing is listed then).
  @visibleForTesting
  static String? processListingScript(String exeName) {
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_. -]{0,63}$').hasMatch(exeName)) {
      return null;
    }
    return _listingScript.replaceAll('@EXE@', exeName);
  }

  /// The processes a launch that found the lock port held may end, read
  /// from the output of [processListingScript]: only other processes
  /// ([ownPid] excluded) run from exactly [ownExecutable] by the same user
  /// as this one. Anything unknown (no owner, no path, no `ME` line) is
  /// left alone.
  @visibleForTesting
  static List<int> zombiePids(
    String listing, {
    required int ownPid,
    required String ownExecutable,
  }) {
    final List<List<String>> rows = <List<String>>[];
    for (final String raw in const LineSplitter().convert(listing)) {
      final String line = raw.replaceAll('\uFEFF', '').trim();
      if (line.isNotEmpty) {
        rows.add(line.split('|').map((String part) => part.trim()).toList());
      }
    }
    String me = '';
    for (final List<String> row in rows) {
      if (row.length == 2 && row[0] == 'ME') {
        me = row[1];
      }
    }
    if (!_isKnownOwner(me)) {
      return const <int>[];
    }
    final String exe = _normalizeWindowsPath(ownExecutable);
    if (exe.isEmpty) {
      return const <int>[];
    }
    final List<int> pids = <int>[];
    for (final List<String> row in rows) {
      if (row.length != 3) {
        continue;
      }
      final int? id = int.tryParse(row[0]);
      if (id == null ||
          id <= 0 ||
          id == ownPid ||
          !_isKnownOwner(row[1]) ||
          row[1].toLowerCase() != me.toLowerCase() ||
          _normalizeWindowsPath(row[2]) != exe ||
          pids.contains(id)) {
        continue;
      }
      pids.add(id);
    }
    return pids;
  }

  static bool _isKnownOwner(String owner) {
    final int slash = owner.lastIndexOf(r'\');
    return owner.isNotEmpty && slash < owner.length - 1;
  }

  static String _normalizeWindowsPath(String path) {
    String p = path.trim().replaceAll('/', r'\');
    if (p.startsWith(r'\\?\')) {
      p = p.substring(4);
    }
    return p.toLowerCase();
  }

  /// `%SystemRoot%\System32` from [environment] (`C:\Windows\System32` when
  /// it is missing or not an absolute local path): system tools are run by
  /// full path, never looked up on `PATH`.
  @visibleForTesting
  static String windowsSystem32(Map<String, String> environment) {
    final String root =
        (environment['SystemRoot'] ?? environment['SYSTEMROOT'] ?? '').trim();
    final bool usable = RegExp(r'^[A-Za-z]:\\[^"<>|?*]*$').hasMatch(root);
    final String base = usable ? root : r'C:\Windows';
    return base.endsWith(r'\') ? '${base}System32' : '$base\\System32';
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

/// Ends hung copies of this very executable run by this user (they hold the
/// lock port without answering). Never anything else: a process that only
/// shares the name, or another user's Zen, is left alone. System
/// tools are run by their full path in `%SystemRoot%\System32`.
Future<void> _cleanupZombieProcesses() async {
  if (!Platform.isWindows) return;
  try {
    final String own = Platform.resolvedExecutable;
    final String? script = ZenSingleInstance.processListingScript(
      own.split(RegExp(r'[\\/]')).last,
    );
    if (script == null) {
      return;
    }
    final String system32 = ZenSingleInstance.windowsSystem32(
      Platform.environment,
    );
    final String? listing = await _runForOutput(
      '$system32\\WindowsPowerShell\\v1.0\\powershell.exe',
      <String>[
        '-NoProfile',
        '-NonInteractive',
        '-EncodedCommand',
        _encodePowerShell(script),
      ],
    );
    if (listing == null) {
      logZenWarning('Single instance: could not list running Zen processes');
      return;
    }
    final List<int> pids = ZenSingleInstance.zombiePids(
      listing,
      ownPid: pid,
      ownExecutable: own,
    );
    if (pids.isEmpty) {
      return;
    }
    logZenWarning(
      'Single instance: ending ${pids.length} hung Zen process(es)',
    );
    await _runForOutput('$system32\\taskkill.exe', <String>[
      '/F',
      for (final int id in pids) ...<String>['/PID', '$id'],
    ]);
  } catch (error, stackTrace) {
    logZenError('Cleaning up hung Zen processes failed', error, stackTrace);
  }
}

/// `-EncodedCommand` form of [script] (base64 of UTF-16LE): no quoting of
/// the command line can change what PowerShell runs.
String _encodePowerShell(String script) {
  final List<int> bytes = <int>[];
  for (final int unit in script.codeUnits) {
    bytes
      ..add(unit & 0xff)
      ..add(unit >> 8);
  }
  return base64.encode(bytes);
}

/// Runs [executable] and returns what it printed when it ended well within
/// [timeout] (`null` otherwise; a process still running is killed).
Future<String?> _runForOutput(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final Process process = await Process.start(executable, arguments);
  final Future<String> output = process.stdout
      .transform(const Utf8Decoder(allowMalformed: true))
      .join();
  unawaited(process.stderr.drain<void>());
  try {
    final int code = await process.exitCode.timeout(timeout);
    final String text = await output;
    return code == 0 ? text : null;
  } on TimeoutException {
    process.kill();
    return null;
  }
}
