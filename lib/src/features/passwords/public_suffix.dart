import 'package:zen/src/features/passwords/public_suffix_rules.dart';

/// Host names as the autofill compares them, and the Public Suffix List
/// that tells which part of a host one person or company registered.
///
/// A host is compared in its ASCII form (IDNA, as browsers send it to a
/// server and report it to the autofill): lower case; the ideographic full
/// stops `。 ． ｡` as dots; full-width Latin letters and digits as their
/// ASCII ones; then every label with a letter outside ASCII in punycode
/// (`bücher.de` → `xn--bcher-kva.de`, RFC 3492). Nothing else is mapped:
/// letters of other alphabets that look like Latin ones are never folded
/// into them, so `exаmple.com` with a Cyrillic `а` is `xn--exmple-4nf.com`
/// and stays another host than `example.com`. Unicode normalisation (NFC)
/// is not applied: a letter typed as a base letter and a combining accent
/// does not match the same letter typed whole (keyboards type it whole).

const int _base = 36;
const int _tMin = 1;
const int _tMax = 26;
const int _skew = 38;
const int _damp = 700;
const int _initialBias = 72;
const int _initialN = 128;

/// The longest label of a host name.
const int _maxLabel = 63;

int _adapt(int delta, int points, {required bool first}) {
  int d = first ? delta ~/ _damp : delta ~/ 2;
  d += d ~/ points;
  int k = 0;
  while (d > ((_base - _tMin) * _tMax) ~/ 2) {
    d ~/= _base - _tMin;
    k += _base;
  }
  return k + ((_base - _tMin + 1) * d) ~/ (d + _skew);
}

int _digit(int d) => d < 26 ? 0x61 + d : 0x30 + d - 26;

/// [label] in punycode (RFC 3492), without the `xn--` prefix; null when it
/// cannot be encoded (a lone surrogate, or longer than any host has).
String? punycodeEncode(String label) {
  final List<int> input = label.runes.toList();
  if (input.length > 256 || input.any((int c) => c >= 0xD800 && c < 0xE000)) {
    return null;
  }
  final List<int> out = <int>[
    for (final int c in input)
      if (c < 0x80) c,
  ];
  final int basic = out.length;
  int handled = basic;
  if (basic > 0) {
    out.add(0x2D);
  }
  int n = _initialN;
  int delta = 0;
  int bias = _initialBias;
  while (handled < input.length) {
    int m = 0x10FFFF + 1;
    for (final int c in input) {
      if (c >= n && c < m) {
        m = c;
      }
    }
    delta += (m - n) * (handled + 1);
    n = m;
    for (final int c in input) {
      if (c < n) {
        delta++;
      }
      if (c == n) {
        int q = delta;
        for (int k = _base; ; k += _base) {
          final int t = k <= bias
              ? _tMin
              : (k >= bias + _tMax ? _tMax : k - bias);
          if (q < t) {
            break;
          }
          out.add(_digit(t + (q - t) % (_base - t)));
          q = (q - t) ~/ (_base - t);
        }
        out.add(_digit(q));
        bias = _adapt(delta, handled + 1, first: handled == basic);
        delta = 0;
        handled++;
      }
    }
    delta++;
    n++;
  }
  return String.fromCharCodes(out);
}

final RegExp _fullStops = RegExp('[。．｡]');

/// [host] in the ASCII form the autofill compares (see the top of this
/// file); null when a label cannot be one. Lower case. Labels are not
/// otherwise checked here.
String? asciiHost(String host) {
  final StringBuffer folded = StringBuffer();
  for (final int c in host.replaceAll(_fullStops, '.').runes) {
    // Full-width forms of ASCII (`ｅｘａｍｐｌｅ`) are the ASCII letters.
    folded.writeCharCode(c >= 0xFF01 && c <= 0xFF5E ? c - 0xFEE0 : c);
  }
  final List<String> labels = folded.toString().toLowerCase().split('.');
  for (int i = 0; i < labels.length; i++) {
    final String label = labels[i];
    if (label.codeUnits.every((int u) => u < 0x80)) {
      continue;
    }
    final String? encoded = punycodeEncode(label);
    if (encoded == null || encoded.length + 4 > _maxLabel) {
      return null;
    }
    labels[i] = 'xn--$encoded';
  }
  return labels.join('.');
}

/// The Public Suffix List (https://publicsuffix.org/list/): the suffixes
/// under which anyone may register a name (`com`, `co.uk`, `gdynia.pl`),
/// its ICANN part and its private part (`github.io`, `trycloudflare.com`,
/// `s3.amazonaws.com`: hosts where each subdomain is somebody else's), with
/// its wildcard (`*.ck`) and exception (`!www.ck`) rules, as the list's
/// own algorithm reads them.
final class PublicSuffixList {
  /// The list of [text]: one rule per line; `//` starts a comment; a rule
  /// in Unicode is taken in its ASCII form ([asciiHost]).
  factory PublicSuffixList.parse(String text) {
    final Set<String> rules = <String>{};
    final Set<String> wildcards = <String>{};
    final Set<String> exceptions = <String>{};
    for (final String raw in text.split('\n')) {
      final String line = raw.trim().split(RegExp(r'\s')).first;
      if (line.isEmpty || line.startsWith('//')) {
        continue;
      }
      if (line.startsWith('!')) {
        final String? rule = asciiHost(line.substring(1));
        if (rule != null) {
          exceptions.add(rule);
        }
      } else if (line.startsWith('*.')) {
        final String? rule = asciiHost(line.substring(2));
        if (rule != null) {
          wildcards.add(rule);
        }
      } else if (asciiHost(line) case final String rule) {
        rules.add(rule);
      }
    }
    return PublicSuffixList._(rules, wildcards, exceptions);
  }

  PublicSuffixList._(this._rules, this._wildcards, this._exceptions);

  final Set<String> _rules;

  /// `*.ck` kept as `ck`.
  final Set<String> _wildcards;

  /// `!www.ck` kept as `www.ck`.
  final Set<String> _exceptions;

  /// How many rules the list has.
  int get length => _rules.length + _wildcards.length + _exceptions.length;

  /// How many of the last of [labels] are the public suffix: the prevailing
  /// rule is an exception rule when one matches (its own labels but the
  /// first), else the matching rule of the most labels, else `*` (the last
  /// label alone).
  int _suffixLabels(List<String> labels) {
    final int n = labels.length;
    for (int i = 0; i < n; i++) {
      if (_exceptions.contains(labels.sublist(i).join('.'))) {
        return n - i - 1;
      }
    }
    for (int i = 0; i < n; i++) {
      if (_rules.contains(labels.sublist(i).join('.')) ||
          (i + 1 < n && _wildcards.contains(labels.sublist(i + 1).join('.')))) {
        return n - i;
      }
    }
    return 1;
  }

  static List<String>? _labelsOf(String host) {
    final String? ascii = asciiHost(host);
    if (ascii == null || ascii.isEmpty) {
      return null;
    }
    final List<String> labels = ascii.split('.');
    return labels.any((String l) => l.isEmpty) ? null : labels;
  }

  /// The public suffix of [host] (`co.uk` for `www.example.co.uk`); null
  /// when [host] is not a host name (empty, or with an empty label).
  String? publicSuffix(String host) {
    final List<String>? labels = _labelsOf(host);
    if (labels == null) {
      return null;
    }
    return labels.sublist(labels.length - _suffixLabels(labels)).join('.');
  }

  /// The part of [host] one owner registered: its public suffix and one
  /// label more (`example.co.uk` for `www.example.co.uk`), in ASCII form;
  /// null when [host] is itself a public suffix or not a host name.
  String? registrableDomain(String host) {
    final List<String>? labels = _labelsOf(host);
    if (labels == null) {
      return null;
    }
    final int suffix = _suffixLabels(labels);
    if (labels.length <= suffix) {
      return null;
    }
    return labels.sublist(labels.length - suffix - 1).join('.');
  }
}

PublicSuffixList? _list;

/// The list this build carries ([kPublicSuffixListVersion]), read on its
/// first use and kept.
PublicSuffixList get publicSuffixList =>
    _list ??= PublicSuffixList.parse(kPublicSuffixRules);
