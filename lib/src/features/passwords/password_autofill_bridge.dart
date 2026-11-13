import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_match.dart';

/// A login form in another app or a browser that asked Zen for a login
/// (Android's autofill, ZenAutofillService.kt). It holds who asked, never
/// a value: [packageName] is the app as Android reported it, with its
/// certificates ([appCertificates]); [webDomain] and [webScheme] the page,
/// only when the app is a known browser signed by its maker (any other app
/// is matched by its package alone, whatever page it claims).
@immutable
final class PasswordAutofillRequest {
  const PasswordAutofillRequest({
    required this.id,
    required this.packageName,
    this.appLabel,
    this.appCertificates = const <String>[],
    this.appCertificate,
    this.webDomain,
    this.webScheme,
    this.hasUsernameField = false,
    this.hasPasswordField = true,
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
    final Object? certificates = raw['certificates'];
    final Object? certificate = raw['certificate'];
    return PasswordAutofillRequest(
      id: id,
      packageName: package,
      appLabel: _label(raw['label']),
      appCertificates: <String>[
        if (certificates is List)
          for (final Object? c in certificates.take(64))
            if (c is String && _digest.hasMatch(c)) c,
      ],
      appCertificate: certificate is String && _sha512.hasMatch(certificate)
          ? certificate
          : null,
      webDomain: domain is String && domain.isNotEmpty && domain.length <= 253
          ? domain
          : null,
      webScheme: scheme == 'https' || scheme == 'http'
          ? scheme as String
          : null,
      hasUsernameField: raw['username'] == true,
      // An answer from before the login-only forms always had one.
      hasPasswordField: raw['password'] != false,
    );
  }

  static final RegExp _package = RegExp(
    r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
  );
  static final RegExp _digest = RegExp(r'^([0-9a-f]{64}|[0-9a-f]{128})$');
  static final RegExp _sha512 = RegExp(r'^[0-9a-f]{128}$');

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

  /// The SHA-256 and SHA-512 digests (lower-case hex) of the certificates
  /// the app is signed with or proved it rotated from: an entry that names
  /// a certificate matches only one of these ([matchPasswordEntries]).
  /// Empty for a page, or when Android does not tell.
  final List<String> appCertificates;

  /// The SHA-512 of the certificate the app is signed with now; null for a
  /// page, an app with several signers, or when Android does not tell.
  final String? appCertificate;
  final String? webDomain;
  final String? webScheme;

  /// Whether the form has a login field.
  final bool hasUsernameField;

  /// Whether the form has a password field (the first page of a login in
  /// two steps has none).
  final bool hasPasswordField;

  /// A page in a browser (matched by its address), not an app.
  bool get isWeb => webDomain != null;

  /// Whether an entry of [login] and [password] has anything this form
  /// takes: the Android side fills only the fields the form has.
  bool canFillWith({required String login, required String password}) =>
      (hasPasswordField && password.isNotEmpty) ||
      (hasUsernameField && login.isNotEmpty);

  /// The page as the matching reads it: its host and port, with the scheme
  /// the browser reported (http when it gave none, as the matching takes
  /// it). Null for an app, or when the page's address is not a host.
  ({String scheme, String host, int? port})? get _page {
    final String domain = webDomain?.trim() ?? '';
    if (domain.isEmpty) {
      return null;
    }
    final String scheme = webScheme ?? 'http';
    final Uri? uri = Uri.tryParse(
      domain.contains('://') ? domain : '$scheme://$domain',
    );
    final String? host = uri == null ? null : normalizePasswordHost(uri.host);
    if (host == null) {
      return null;
    }
    return (scheme: scheme, host: host, port: uri!.hasPort ? uri.port : null);
  }

  /// The address a new entry for this form is saved under, so that the
  /// next request from the same page or app finds it as an exact match
  /// ([matchPasswordEntries]): the page's scheme, host and port as the
  /// browser reported them, or the app's package with the certificate it
  /// is signed with now ([passwordAppAddress]: on another phone an app
  /// under the same name but signed by someone else does not get it; an
  /// app whose key rotates keeps it, as Android reports the old certificate
  /// with the new). Taken from the request alone, never from anything the
  /// page or app wrote. Null when the page's address is not a host.
  String? get newEntryAddress {
    if (!isWeb) {
      return passwordAppAddress(packageName, sha512: appCertificate);
    }
    final ({String scheme, String host, int? port})? page = _page;
    if (page == null) {
      return null;
    }
    final int? port = page.port;
    return '${page.scheme}://${page.host}${port == null ? '' : ':$port'}';
  }

  /// The name a new entry for this form starts with: the page's host, or
  /// the app's name (its package when it gives none).
  String get newEntryName {
    final String name = _page?.host ?? appLabel ?? packageName;
    return name.length > kMaxPasswordNameChars
        ? name.substring(0, kMaxPasswordNameChars)
        : name;
  }

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

  /// [on]: a new login for [request] is being typed, so the Android side
  /// keeps it open a few minutes from when it opened instead of one; off:
  /// back to the picker, a minute to pick (never past those few minutes).
  /// Zen locking or the person leaving still ends it.
  Future<void> hold(PasswordAutofillRequest request, {required bool on}) async {
    await _call<bool>('hold', <String, Object?>{'id': request.id, 'on': on});
  }

  /// [on]: a picker is up, and touches that come through another app's
  /// window drawn over Zen are dropped; off: that picker went. They pass
  /// again only once no picker is up (an older one, under a page kept open
  /// for a new login, can go while a newer one is up).
  Future<void> guard({required bool on}) async {
    final bool was = _guards > 0;
    _guards = on ? _guards + 1 : (_guards > 0 ? _guards - 1 : 0);
    if (was != _guards > 0) {
      await _call<bool>('guard', <String, Object?>{'on': on});
    }
  }

  int _guards = 0;

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
