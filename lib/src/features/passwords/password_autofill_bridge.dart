import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// A login form in another app or a browser that asked Zen for a login
/// (Android's autofill, ZenAutofillService.kt). It holds who asked, never
/// a value: [packageName] is the app as Android reported it; [webDomain]
/// and [webScheme] the page, only when the app is a known browser (any
/// other app is matched by its package alone, whatever page it claims).
@immutable
final class PasswordAutofillRequest {
  const PasswordAutofillRequest({
    required this.id,
    required this.packageName,
    this.appLabel,
    this.webDomain,
    this.webScheme,
    this.hasUsernameField = false,
  });

  /// The request as the Android side describes it; null when anything in
  /// it does not look right.
  static PasswordAutofillRequest? fromMap(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? id = raw['id'];
    final Object? package = raw['package'];
    if (id is! String ||
        id.isEmpty ||
        id.length > 64 ||
        package is! String ||
        package.length > 255 ||
        !_package.hasMatch(package)) {
      return null;
    }
    final Object? domain = raw['webDomain'];
    final Object? scheme = raw['webScheme'];
    return PasswordAutofillRequest(
      id: id,
      packageName: package,
      appLabel: _label(raw['label']),
      webDomain: domain is String && domain.isNotEmpty && domain.length <= 253
          ? domain
          : null,
      webScheme: scheme == 'https' || scheme == 'http'
          ? scheme as String
          : null,
      hasUsernameField: raw['username'] == true,
    );
  }

  static final RegExp _package = RegExp(
    r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
  );

  /// An app's own name, on one short line (any app can call itself
  /// anything: it is only ever shown next to the package).
  static String? _label(Object? raw) {
    if (raw is! String) {
      return null;
    }
    final String line = raw
        .replaceAll(
          RegExp(
            r'[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]',
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (line.isEmpty) {
      return null;
    }
    return line.length > 60 ? '${line.substring(0, 60)}…' : line;
  }

  final String id;
  final String packageName;
  final String? appLabel;
  final String? webDomain;
  final String? webScheme;

  /// Whether the form has a login field to fill besides the password.
  final bool hasUsernameField;

  /// A page in a browser (matched by its address), not an app.
  bool get isWeb => webDomain != null;

  /// Says nothing of who asked: this may end up in a log.
  @override
  String toString() => 'PasswordAutofillRequest(${isWeb ? 'web' : 'app'})';
}

/// Whether Zen can fill other apps, and whether the person switched it on.
enum PasswordAutofillState {
  /// Not Android, or Android before 9.
  unsupported,

  /// Another service (or none) is picked in Android's settings.
  off,

  /// Zen is the autofill service.
  on,
}

/// The picker's way to Android's autofill (`zen/autofill`,
/// ZenAutofillBridge.kt). The Android side holds at most one request and
/// says [changes] when one opens or ends; [fill] hands it exactly the
/// login and password of the entry the person picked, nothing else, and
/// only for the request still open.
///
/// Nothing about the request (the app, the page) or the entry goes to the
/// log: only that a call failed.
final class PasswordAutofillBridge {
  PasswordAutofillBridge({MethodChannel? channel, bool? supported})
    : _channel = channel ?? const MethodChannel(channelName),
      supported =
          supported ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    if (this.supported) {
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'changed') {
          _changes.changed();
        }
        return null;
      });
    }
  }

  static const String channelName = 'zen/autofill';

  final MethodChannel _channel;

  /// Android: the only system with this autofill.
  final bool supported;

  /// Fires when a request opened or ended on the Android side.
  Listenable get changes => _changes;
  final _Changes _changes = _Changes();

  Future<T?> _call<T>(String method, [Map<String, Object?>? arguments]) async {
    if (!supported) {
      return null;
    }
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on Object catch (error) {
      logZenWarning('Autofill ($method) failed: ${error.runtimeType}');
      return null;
    }
  }

  /// The open request, if there is one.
  Future<PasswordAutofillRequest?> pending() async =>
      PasswordAutofillRequest.fromMap(await _call<Object?>('pending'));

  /// Fills [request]'s form with [login] and [password] (the entry the
  /// person picked) and goes back to that app. False when the request is
  /// no longer open: nothing was filled then.
  Future<bool> fill(
    PasswordAutofillRequest request, {
    required String login,
    required String password,
  }) async =>
      await _call<bool>('fill', <String, Object?>{
        'id': request.id,
        'login': login,
        'password': password,
      }) ??
      false;

  /// Ends [request] with nothing filled; [back] returns to that app (the
  /// person closed the picker).
  Future<void> cancel(
    PasswordAutofillRequest request, {
    bool back = false,
  }) async {
    await _call<bool>('cancel', <String, Object?>{
      'id': request.id,
      'back': back,
    });
  }

  /// [on]: touches that come through another app's window drawn over Zen
  /// are dropped (the picker is up).
  Future<void> guard({required bool on}) async {
    await _call<bool>('guard', <String, Object?>{'on': on});
  }

  /// Whether Zen can fill other apps here and is switched on for it.
  Future<PasswordAutofillState> state() async {
    final Map<Object?, Object?>? raw = await _call<Map<Object?, Object?>>(
      'status',
    );
    if (raw == null || raw['supported'] != true) {
      return PasswordAutofillState.unsupported;
    }
    return raw['enabled'] == true
        ? PasswordAutofillState.on
        : PasswordAutofillState.off;
  }

  /// Opens Android's page where the autofill service is picked.
  Future<bool> openSettings() async =>
      await _call<bool>('openSettings') ?? false;
}

final class _Changes extends ChangeNotifier {
  void changed() => notifyListeners();
}

/// The autofill's way to Android (one per app; the Android side keeps one
/// request for the whole app).
final Provider<PasswordAutofillBridge> passwordAutofillBridgeProvider =
    Provider<PasswordAutofillBridge>((Ref ref) => PasswordAutofillBridge());
