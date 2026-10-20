import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart' show contentHash;

/// What this person hid on this phone after reporting it (§21.4).
///
/// A report hides the reported post, comment, message or dating profile
/// from the reporter at once, whatever the pyramid decides. The keys are
/// opaque: [idKey] for content with an id (a post, a comment, a message),
/// [textKey] (the hash the pyramid bans content by) for content that has
/// none, [datingKeyOf] for a dating profile. [keys] are kept on disk;
/// [shown] holds the ones the person chose to look at anyway, and lasts
/// until the app is closed.
@immutable
final class HiddenByMe {
  const HiddenByMe({
    this.keys = const <String>{},
    this.shown = const <String>{},
  });

  /// Hidden, kept on disk (the oldest first).
  final Set<String> keys;

  /// Shown anyway, this time only.
  final Set<String> shown;

  /// The key of content with an [id].
  static String idKey(String id) => 'id:$id';

  /// The key of content known only by its [text] (the pyramid's hash).
  static String textKey(String text) => 'h:${contentHash(text)}';

  /// The key of the dating profile [key].
  static String datingKeyOf(String key) => 'dk:$key';

  /// The keys a report of this content hides: the id when there is one,
  /// else the hash of the text; plus the dating profile.
  static List<String> keysFor({
    String id = '',
    String? textHash,
    String? datingKey,
  }) => <String>[
    if (id.isNotEmpty)
      idKey(id)
    else if (textHash != null && textHash.isNotEmpty)
      'h:$textHash',
    if (datingKey != null && datingKey.isNotEmpty) datingKeyOf(datingKey),
  ];

  /// Whether the content with this [id] / [text] / [datingKey] is hidden
  /// now (hidden, and not shown anyway).
  bool hides({String id = '', String text = '', String datingKey = ''}) {
    if (keys.isEmpty) {
      return false;
    }
    final String own = id.isNotEmpty
        ? idKey(id)
        : (text.isNotEmpty ? textKey(text) : '');
    final String dating = datingKey.isEmpty ? '' : datingKeyOf(datingKey);
    return (own.isNotEmpty && keys.contains(own) && !shown.contains(own)) ||
        (dating.isNotEmpty && keys.contains(dating) && !shown.contains(dating));
  }

  HiddenByMe copyWith({Set<String>? keys, Set<String>? shown}) =>
      HiddenByMe(keys: keys ?? this.keys, shown: shown ?? this.shown);
}

/// The hidden content of this phone ([HiddenByMe]), kept in the app's
/// encrypted store.
final NotifierProvider<HiddenByMeNotifier, HiddenByMe> hiddenByMeProvider =
    NotifierProvider<HiddenByMeNotifier, HiddenByMe>(HiddenByMeNotifier.new);

/// Hides content after a report, shows it anyway on request, and keeps the
/// list (not more than [maxKept] entries: the oldest go).
final class HiddenByMeNotifier extends Notifier<HiddenByMe> {
  /// Where the list is kept in the encrypted store.
  static const String diskKey = 'moderation/hidden-by-me';

  /// Entries kept; a long-forgotten report loses its hiding first.
  static const int maxKept = 2000;

  /// The longest key kept (anything longer is not one of ours).
  static const int _maxKeyLength = 200;

  late LedgerDisk _disk;
  Future<void> _writing = Future<void>.value();

  @override
  HiddenByMe build() {
    _disk = ref.read(ledgerDiskProvider);
    unawaitedLogged(_load(), context: 'Odczyt ukrytych treści');
    return const HiddenByMe();
  }

  Future<void> _load() async {
    final Uint8List? raw = await _disk.read(diskKey);
    if (raw == null || !ref.mounted) {
      return;
    }
    final Object? json = jsonDecode(utf8.decode(raw));
    if (json is! List) {
      return;
    }
    final Set<String> loaded = <String>{
      for (final Object? k in json)
        if (k is String && k.isNotEmpty && k.length <= _maxKeyLength) k,
      // Hidden while the file was being read.
      ...state.keys,
    };
    state = state.copyWith(keys: _trimmed(loaded));
  }

  Set<String> _trimmed(Set<String> keys) {
    if (keys.length <= maxKept) {
      return keys;
    }
    return keys.skip(keys.length - maxKept).toSet();
  }

  /// Hides content by [keys] (see [HiddenByMe.keysFor]); the returned
  /// future completes when the list is on disk.
  Future<void> hide(Iterable<String> keys) {
    final List<String> fresh = <String>[
      for (final String k in keys)
        if (k.isNotEmpty && k.length <= _maxKeyLength) k,
    ];
    if (fresh.isEmpty) {
      return Future<void>.value();
    }
    // A report of something hidden before is its newest entry again.
    final Set<String> next = <String>{
      for (final String k in state.keys)
        if (!fresh.contains(k)) k,
      ...fresh,
    };
    state = state.copyWith(
      keys: _trimmed(next),
      // A new report hides it for real, even if it was shown anyway.
      shown: <String>{
        for (final String k in state.shown)
          if (!fresh.contains(k)) k,
      },
    );
    return _save();
  }

  /// Shows [key] anyway until the app is closed.
  void show(String key) {
    if (state.shown.contains(key)) {
      return;
    }
    state = state.copyWith(shown: <String>{...state.shown, key});
  }

  /// Shows the content with this [id] / [text] / [datingKey] anyway.
  void showContent({String id = '', String text = '', String datingKey = ''}) {
    if (id.isNotEmpty) {
      show(HiddenByMe.idKey(id));
    } else if (text.isNotEmpty) {
      show(HiddenByMe.textKey(text));
    }
    if (datingKey.isNotEmpty) {
      show(HiddenByMe.datingKeyOf(datingKey));
    }
  }

  Future<void> _save() {
    final Uint8List bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(state.keys.toList())),
    );
    final Future<void> run = _writing.then((_) => _disk.write(diskKey, bytes));
    _writing = run.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        logZenError('Zapis ukrytych treści', error, stackTrace);
      },
    );
    return _writing;
  }
}

/// The notifier of the app around [context], or null where there is no
/// app (a bare widget test).
HiddenByMeNotifier? hiddenByMeOf(BuildContext context) {
  try {
    return ProviderScope.containerOf(
      context,
      listen: false,
    ).read(hiddenByMeProvider.notifier);
  } on Object {
    return null;
  }
}
