import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/social/mentions.dart';

/// What was written and not sent yet: a message, a comment or a post, its
/// text as stored (`<@N>` tokens of [mentions]), and for a post who is to
/// see it ([audience], the name of an `Audience`).
@immutable
final class ComposerDraft {
  const ComposerDraft({
    required this.text,
    this.mentions = const <Mention>[],
    this.audience,
  });

  final String text;
  final List<Mention> mentions;
  final String? audience;

  bool get isEmpty => text.trim().isEmpty;

  Map<String, Object?> _toJson() => <String, Object?>{
    't': text,
    if (mentions.isNotEmpty) 'm': mentionsToJson(mentions),
    if (audience != null) 'a': audience,
  };

  static ComposerDraft? _fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? text = json['t'];
    final Object? audience = json['a'];
    if (text is! String || text.trim().isEmpty) {
      return null;
    }
    return ComposerDraft(
      text: text,
      mentions: mentionsFromJson(json['m']),
      audience: audience is String ? audience : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ComposerDraft &&
      other.text == text &&
      other.audience == audience &&
      listEquals(other.mentions, mentions);

  @override
  int get hashCode => Object.hash(text, audience, Object.hashAll(mentions));
}

/// Keeps what was written and not sent yet (per conversation, per post's
/// comments, the new post) in the account's encrypted store, next to the
/// other settings of the screens, so that it is still there when the
/// screen is opened again, also after the app was closed.
///
/// A draft is written a moment after the last change, at once when it is
/// sent (emptied) and when the app leaves the screen. The store is the
/// open account's own; a wipe drops it ([forget]).
final class ComposerDrafts with WidgetsBindingObserver {
  ComposerDrafts(
    this._disk, {
    this.saveDelay = const Duration(milliseconds: 600),
  });

  /// Where the drafts live.
  static const String key = 'ui/drafts';

  /// Drafts kept at most (the oldest go first).
  static const int maxDrafts = 100;

  /// The longest text kept of a draft.
  static const int maxChars = 20000;

  /// The draft of the conversation with [address].
  static String peerChat(String address) => 'peer:$address';

  /// The draft of the group [groupId]'s chat (and its board).
  static String groupChat(String groupId) => 'group:$groupId';

  /// The draft of a comment under the post [postId].
  static String comment(String postId) => 'comment:$postId';

  /// The draft of a new post.
  static const String newPost = 'post';

  final LedgerDisk _disk;
  final Duration saveDelay;

  /// Oldest first.
  final LinkedHashMap<String, ComposerDraft> _drafts =
      LinkedHashMap<String, ComposerDraft>();

  /// Changed before the stored drafts were read: those win over the store.
  final Set<String> _touched = <String>{};

  Future<void>? _loading;
  bool _loaded = false;
  Timer? _timer;
  bool _dirty = false;
  bool _forgotten = false;

  /// The stored drafts have been read.
  bool get isLoaded => _loaded;

  /// Reads the stored drafts (once).
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final Uint8List? raw = await _disk.read(key);
      if (_forgotten || raw == null || raw.isEmpty) {
        return;
      }
      final Object? json = jsonDecode(utf8.decode(raw));
      final Object? list = json is Map ? json['drafts'] : null;
      if (list is! Map) {
        return;
      }
      final Map<String, ComposerDraft> stored = <String, ComposerDraft>{};
      for (final MapEntry<Object?, Object?> e in list.entries) {
        final Object? id = e.key;
        final ComposerDraft? draft = ComposerDraft._fromJson(e.value);
        if (id is String && draft != null && !_touched.contains(id)) {
          stored[id] = draft;
        }
      }
      // What was stored is older than what was written since.
      final Map<String, ComposerDraft> now = Map<String, ComposerDraft>.of(
        _drafts,
      );
      _drafts
        ..clear()
        ..addAll(stored)
        ..addAll(now);
    } on Object {
      // Drafts that cannot be read are only not offered again.
    } finally {
      _loaded = true;
    }
  }

  /// The draft [id], when there is one (and the stored ones were read).
  ComposerDraft? operator [](String id) => _drafts[id];

  /// [draft] is what [id] holds now; an empty one drops it.
  void put(String id, ComposerDraft draft) {
    if (_forgotten) {
      return;
    }
    _touched.add(id);
    if (draft.isEmpty) {
      if (_drafts.remove(id) != null) {
        _changed(now: true);
      }
      return;
    }
    final ComposerDraft kept = draft.text.length > maxChars
        ? ComposerDraft(
            text: draft.text.substring(0, maxChars),
            mentions: draft.mentions,
            audience: draft.audience,
          )
        : draft;
    if (_drafts[id] == kept) {
      return;
    }
    _drafts
      ..remove(id)
      ..[id] = kept;
    while (_drafts.length > maxDrafts) {
      _drafts.remove(_drafts.keys.first);
    }
    _changed();
  }

  /// [id] was sent: its draft goes.
  void clear(String id) => put(id, const ComposerDraft(text: ''));

  void _changed({bool now = false}) {
    _dirty = true;
    _timer?.cancel();
    if (now) {
      _timer = null;
      unawaited(flush());
    } else {
      _timer = Timer(saveDelay, () => unawaited(flush()));
    }
  }

  /// Writes the drafts now, when they changed.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    if (!_dirty || _forgotten) {
      return;
    }
    // The stored ones first, or writing would drop them.
    await load();
    if (_forgotten) {
      return;
    }
    _dirty = false;
    try {
      if (_drafts.isEmpty) {
        await _disk.delete(key);
      } else {
        await _disk.write(
          key,
          Uint8List.fromList(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'drafts': <String, Object?>{
                  for (final MapEntry<String, ComposerDraft> e
                      in _drafts.entries)
                    e.key: e.value._toJson(),
                },
              }),
            ),
          ),
        );
      }
    } on Object {
      // Kept in memory; written with the next change.
      _dirty = true;
    }
  }

  /// The account is being wiped: nothing is kept or written any more.
  void forget() {
    _forgotten = true;
    _timer?.cancel();
    _timer = null;
    _drafts.clear();
    _dirty = false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The app may be killed without another word once it is away.
    if (state != AppLifecycleState.resumed) {
      unawaited(flush());
    }
  }

  void dispose() {
    if (_timer != null) {
      unawaited(flush());
    }
    _timer?.cancel();
    _timer = null;
  }
}

/// The drafts of the open account (the ledger's store is its own).
final Provider<ComposerDrafts> composerDraftsProvider =
    Provider<ComposerDrafts>((Ref ref) {
      final ComposerDrafts drafts = ComposerDrafts(
        ref.read(ledgerDiskProvider),
      );
      unawaited(drafts.load());
      WidgetsBinding.instance.addObserver(drafts);
      ref.onDispose(() {
        WidgetsBinding.instance.removeObserver(drafts);
        drafts.dispose();
      });
      return drafts;
    });
