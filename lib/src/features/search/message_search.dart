import 'dart:async';

import 'package:zen/src/core/utils/background_work.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/search/search_text.dart';

/// Text of this many bytes or more is folded in a short-lived isolate
/// ([runSizedWork]): a long history does not stop the screen.
const int kSearchFoldInIsolateBytes = 256 * 1024;

/// A scan over more messages than this yields to the screen between
/// pieces of this size.
const int kSearchScanSlice = 8000;

/// What a search looks at in [message]: the text of a text message (names
/// in place of mentions), the name of a file. Nothing for photos, voice
/// messages, films, deleted messages and the app's own notes.
String searchableTextOf(ChatMessage message) {
  if (message.isSystem || message.isDeleted) {
    return '';
  }
  return switch (message.type) {
    ChatMessageType.text => message.plainText,
    ChatMessageType.file => message.fileName ?? '',
    _ => '',
  };
}

/// Every text of [texts] through [foldForSearch], in a short-lived isolate
/// when there is much of it.
Future<List<String>> foldAllForSearch(List<String> texts) {
  int bytes = 0;
  for (final String text in texts) {
    bytes += text.length * 2;
  }
  return runSizedWork<List<String>>(
    bytes,
    () => <String>[for (final String text in texts) foldForSearch(text)],
    threshold: kSearchFoldInIsolateBytes,
  );
}

/// One conversation's messages as search sees them, in the order of the
/// conversation (oldest first): only what can be found (see
/// [searchableTextOf]), folded once. Kept in memory while the search is
/// open, never written anywhere.
final class ConversationSearchIndex {
  List<String> _ids = const <String>[];
  List<int> _times = const <int>[];
  List<String> _texts = const <String>[];
  List<String> _folded = const <String>[];

  /// Messages that can be found.
  int get length => _ids.length;

  String idAt(int i) => _ids[i];

  int timeAt(int i) => _times[i];

  String textAt(int i) => _texts[i];

  /// The text at [i] through [foldForSearch].
  String foldedAt(int i) => _folded[i];

  /// Builds the index of [thread]. Messages already in it with the same
  /// text are not folded again (a new message costs one fold). [hidden]
  /// leaves out what the person hid.
  Future<void> update(
    List<ChatMessage> thread, {
    bool Function(ChatMessage message)? hidden,
  }) async {
    final Map<String, int> before = <String, int>{
      for (int i = 0; i < _ids.length; i++) _ids[i]: i,
    };
    final List<String> ids = <String>[];
    final List<int> times = <int>[];
    final List<String> texts = <String>[];
    final List<String?> folded = <String?>[];
    final List<int> missing = <int>[];
    for (final ChatMessage message in thread) {
      if (hidden != null && hidden(message)) {
        continue;
      }
      final String text = searchableTextOf(message);
      if (text.trim().isEmpty) {
        continue;
      }
      final int? was = before[message.id];
      final String? kept = was != null && _texts[was] == text
          ? _folded[was]
          : null;
      if (kept == null) {
        missing.add(texts.length);
      }
      ids.add(message.id);
      times.add(message.sentAtMillis);
      texts.add(text);
      folded.add(kept);
    }
    if (missing.isNotEmpty) {
      final List<String> fresh = await foldAllForSearch(<String>[
        for (final int i in missing) texts[i],
      ]);
      for (int k = 0; k < missing.length; k++) {
        folded[missing[k]] = fresh[k];
      }
    }
    _ids = ids;
    _times = times;
    _texts = texts;
    _folded = <String>[for (final String? f in folded) f!];
  }

  /// The positions of the messages [query] matches, newest first, at most
  /// [limit]. A long history is scanned in slices with the screen getting
  /// its frames in between; [cancelled] stops a scan that is no longer
  /// wanted (the result is then empty).
  Future<List<int>> find(
    SearchQuery query, {
    int limit = 1 << 30,
    bool Function()? cancelled,
  }) async {
    final List<int> found = <int>[];
    if (!query.searchesMessages) {
      return found;
    }
    final List<String> folded = _folded;
    int i = folded.length - 1;
    while (i >= 0 && found.length < limit) {
      final int stop = folded.length > kSearchScanSlice
          ? (i - kSearchScanSlice).clamp(-1, i)
          : -1;
      for (; i > stop && found.length < limit; i--) {
        if (query.matchesFolded(folded[i])) {
          found.add(i);
        }
      }
      if (i >= 0 && folded.length > kSearchScanSlice) {
        await Future<void>.delayed(Duration.zero);
        if (cancelled?.call() ?? false) {
          return <int>[];
        }
      }
    }
    return found;
  }

  /// How many messages [query] matches (no more than [limit] are counted).
  int count(SearchQuery query, {int limit = 1 << 30}) {
    if (!query.searchesMessages) {
      return 0;
    }
    int n = 0;
    for (final String f in _folded) {
      if (query.matchesFolded(f) && ++n >= limit) {
        break;
      }
    }
    return n;
  }
}
