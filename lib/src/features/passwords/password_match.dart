import 'package:flutter/foundation.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/public_suffix.dart';

/// What an entry's address points at.
enum PasswordAddressKind {
  /// A web page (`https://…`, `http://…`, or a bare host taken as https).
  web,

  /// An Android app by its package name.
  app,
}

final RegExp _package = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
);
final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _hostChars = RegExp(r'^[^\s/\\?#@:]+$');

/// An entry's address, read for matching: a web page (scheme, host, port)
/// or an Android app (package name).
@immutable
final class PasswordAddress {
  const PasswordAddress.web({
    required this.scheme,
    required this.host,
    this.port,
  }) : kind = PasswordAddressKind.web,
       package = null;

  const PasswordAddress.app(String this.package)
    : kind = PasswordAddressKind.app,
      scheme = null,
      host = null,
      port = null;

  final PasswordAddressKind kind;

  /// `https` or `http` (web).
  final String? scheme;

  /// Lower case, without a trailing dot (web).
  final String? host;

  /// Only when the address names one (web).
  final int? port;

  /// The package name, exactly (app).
  final String? package;

  /// [address] as an entry stores it, or null when it is neither a web
  /// address nor an app:
  /// * `https://host[:port]/…`, `http://host[:port]/…`, or a bare host
  ///   (`example.com/login`), which is taken as https;
  /// * `android-app://com.example`, `androidapp://com.example` (Bitwarden)
  ///   or `android://<hash>@com.example/` (Chrome, Firefox).
  static PasswordAddress? parse(String address) {
    final String a = address.trim();
    if (a.isEmpty || a.length > kMaxPasswordAddressChars) {
      return null;
    }
    final String lower = a.toLowerCase();
    for (final String prefix in <String>['android-app://', 'androidapp://']) {
      if (lower.startsWith(prefix)) {
        return _app(a.substring(prefix.length));
      }
    }
    if (lower.startsWith('android://')) {
      String rest = a.substring('android://'.length);
      final int at = rest.lastIndexOf('@');
      if (at >= 0) {
        rest = rest.substring(at + 1);
      }
      return _app(rest);
    }
    final bool hasScheme = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(a);
    final Uri? uri = Uri.tryParse(hasScheme ? a : 'https://$a');
    if (uri == null) {
      return null;
    }
    final String scheme = uri.scheme.toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      return null;
    }
    final String? host = normalizePasswordHost(uri.host);
    if (host == null) {
      return null;
    }
    return PasswordAddress.web(
      scheme: scheme,
      host: host,
      port: uri.hasPort ? uri.port : null,
    );
  }

  static PasswordAddress? _app(String rest) {
    final String name = rest.split('/').first.split('?').first.trim();
    return _package.hasMatch(name) ? PasswordAddress.app(name) : null;
  }

  @override
  String toString() => 'PasswordAddress(${kind.name})';
}

/// [host] as the autofill compares it: in its ASCII form, as browsers
/// report a page ([asciiHost]: lower case, letters of other alphabets in
/// punycode, `bücher.de` as `xn--bcher-kva.de`), without a trailing dot;
/// null when it is not a host. Letters that look like Latin ones are never
/// folded into them, so `exаmple.com` with a Cyrillic `а` stays a
/// different host from `example.com`.
String? normalizePasswordHost(String host) {
  String h = host.trim().toLowerCase();
  if (h.contains('%')) {
    // `Uri` escapes letters of other alphabets (and anything else) in a
    // host: read as the letters themselves.
    try {
      h = Uri.decodeComponent(h);
    } on ArgumentError {
      return null;
    } on FormatException {
      return null;
    }
  }
  if (h.startsWith('[') && h.endsWith(']')) {
    // An IPv6 literal: matched exactly.
    return h.length > 2 ? h : null;
  }
  if (h.contains(':') && RegExp(r'^[0-9a-f:.]+$').hasMatch(h)) {
    // An IPv6 literal as `Uri.host` gives it (without brackets).
    return '[$h]';
  }
  final String? ascii = asciiHost(h);
  if (ascii == null) {
    return null;
  }
  h = ascii;
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  if (h.isEmpty ||
      h.length > 253 ||
      !_hostChars.hasMatch(h) ||
      h.startsWith('.') ||
      h.contains('..')) {
    return null;
  }
  return h;
}

/// The registrable part of [host] by the Public Suffix List
/// ([publicSuffixList]: `example.com` for `login.example.com`,
/// `bank.com.pl` for `www.bank.com.pl`, `sklep.gdynia.pl` for
/// `www.sklep.gdynia.pl`, `victim.github.io` for `a.victim.github.io`),
/// in ASCII form; null for an address, a single label, or a host that is
/// itself a public suffix: those match only exactly.
String? registrablePasswordDomain(String host) {
  final String? h = normalizePasswordHost(host);
  if (h == null || h.startsWith('[') || _ipv4.hasMatch(h)) {
    return null;
  }
  return publicSuffixList.registrableDomain(h);
}

/// How an entry matched a request.
enum PasswordMatchKind {
  /// The same app, or the same host.
  exact,

  /// Another host of the same registrable domain (`login.example.com` for
  /// `example.com`, by the Public Suffix List): the picker shows the
  /// address the entry was saved for beside it.
  sameSite,
}

/// An entry the autofill may offer, and how it matched.
@immutable
final class PasswordMatch {
  const PasswordMatch(this.entry, this.kind);

  final PasswordEntry entry;
  final PasswordMatchKind kind;

  @override
  String toString() => 'PasswordMatch(${entry.id}, ${kind.name})';
}

int _defaultPort(String scheme) => scheme == 'http' ? 80 : 443;

/// The entries of [entries] to offer for a form: in a web page
/// ([webDomain], with its [webScheme] as the system reports them) by the
/// page's host; otherwise in the app [packageName] by its package.
///
/// * A page matches an entry with the same host, or another host of the
///   same registrable domain ([registrablePasswordDomain]). Never by a
///   part of a name: `evil-example.com`, `example.com.evil.net` and
///   `notexample.com` do not match `example.com`; hosts under a public
///   suffix of the Public Suffix List (`co.uk`, `gdynia.pl`, `github.io`,
///   `s3.amazonaws.com`) match only their own registrable name. Both sides
///   are compared in their ASCII form ([normalizePasswordHost]).
/// * A page that is not https ([webScheme] `http`, or not given) never
///   matches an https entry; it matches only entries that say `http://`.
///   An https page matches both.
/// * A port named on either side must be the same.
/// * An app matches only an entry for exactly its package; a web page
///   never matches an app entry, and an app never matches a web entry by
///   any similarity of names.
///
/// Exact matches come first, then by name.
List<PasswordMatch> matchPasswordEntries(
  Iterable<PasswordEntry> entries, {
  String? packageName,
  String? webDomain,
  String? webScheme,
}) {
  final List<PasswordMatch> out = <PasswordMatch>[];
  final String domain = webDomain?.trim() ?? '';
  if (domain.isNotEmpty) {
    final String scheme = (webScheme ?? 'http').trim().toLowerCase();
    if (scheme != 'https' && scheme != 'http') {
      return out;
    }
    final Uri? uri = Uri.tryParse(
      domain.contains('://') ? domain : '$scheme://$domain',
    );
    final String? host = uri == null ? null : normalizePasswordHost(uri.host);
    if (host == null) {
      return out;
    }
    final int? port = uri!.hasPort ? uri.port : null;
    final String? site = registrablePasswordDomain(host);
    for (final PasswordEntry e in entries) {
      final PasswordAddress? a = PasswordAddress.parse(e.address);
      if (a == null || a.kind != PasswordAddressKind.web) {
        continue;
      }
      if (scheme == 'http' && a.scheme == 'https') {
        continue;
      }
      final bool portNamed = a.port != null || port != null;
      if (portNamed &&
          (a.port ?? _defaultPort(a.scheme!)) !=
              (port ?? _defaultPort(scheme))) {
        continue;
      }
      if (a.host == host) {
        out.add(PasswordMatch(e, PasswordMatchKind.exact));
      } else if (site != null && registrablePasswordDomain(a.host!) == site) {
        out.add(PasswordMatch(e, PasswordMatchKind.sameSite));
      }
    }
  } else {
    final String package = packageName?.trim() ?? '';
    if (!_package.hasMatch(package)) {
      return out;
    }
    for (final PasswordEntry e in entries) {
      final PasswordAddress? a = PasswordAddress.parse(e.address);
      if (a != null &&
          a.kind == PasswordAddressKind.app &&
          a.package == package) {
        out.add(PasswordMatch(e, PasswordMatchKind.exact));
      }
    }
  }
  out.sort((PasswordMatch a, PasswordMatch b) {
    if (a.kind != b.kind) {
      return a.kind == PasswordMatchKind.exact ? -1 : 1;
    }
    return comparePasswordEntries(a.entry, b.entry);
  });
  return out;
}
