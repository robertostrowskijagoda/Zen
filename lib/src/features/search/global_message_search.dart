import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/search/message_search.dart';
import 'package:zen/src/features/search/search_text.dart';

/// Results listed under one conversation on the chat list (the rest are
/// counted and found in the conversation itself).
const int kGlobalSearchHitsPerConversation = 3;

/// Results listed in all.
const int kGlobalSearchMaxHits = 150;

/// A conversation the search on the chat list looks through.
@immutable
final class SearchConversation {
  const SearchConversation.peer({
    required String address,
    required this.title,
    this.lastAtMillis = 0,
  }) : id = address,
       isGroup = false;

  const SearchConversation.group({
    required String groupId,
    required this.title,
    this.lastAtMillis = 0,
  }) : id = groupId,
       isGroup = true;

  /// The friend's (or other person's) address, or the group's id.
  final String id;
  final bool isGroup;

  /// The name shown over its results.
  final String title;

  /// Its last activity, when known: conversations are read newest first.
  final int lastAtMillis;

  /// Its key in the [MessageTimelineStore].
  String get storeKey => isGroup ? 'group:$id' : id;

  @override
  bool operator ==(Object other) =>
      other is SearchConversation && other.id == id && other.isGroup == isGroup;

  @override
  int get hashCode => Object.hash(id, isGroup);
}

/// One message found.
@immutable
final class GlobalSearchHit {
  const GlobalSearchHit({
    required this.messageId,
    required this.sentAtMillis,
    required this.snippet,
    required this.ranges,
  });

  final String messageId;
  final int sentAtMillis;

  /// The part of the message around what was found ([searchSnippet]).
  final String snippet;

  /// What to mark in [snippet].
  final List<SearchRange> ranges;
}

/// The messages found in one conversation, newest first.
@immutable
final class GlobalSearchGroup {
  const GlobalSearchGroup({
    required this.conversation,
    required this.hits,
    required this.total,
  });

  final SearchConversation conversation;

  /// The newest results (at most [kGlobalSearchHitsPerConversation]).
  final List<GlobalSearchHit> hits;

  /// How many messages of the conversation match.
  final int total;

  int get newestMillis => hits.isEmpty ? 0 : hits.first.sentAtMillis;
}

/// Search through the messages of every conversation, for the chat list.
///
/// The conversations are read from the store (they are decrypted there,
/// as for showing them) one after another, kept here folded
/// ([ConversationSearchIndex]) while the search is open, and dropped with
/// this object. Nothing is written and nothing leaves the device.
final class GlobalMessageSearch {
  GlobalMessageSearch({required this.store, this.hidden});

  final MessageTimelineStore store;

  /// Leaves out messages the person hid.
  final bool Function(ChatMessage message)? hidden;

  final Map<SearchConversation, ConversationSearchIndex> _indexes =
      <SearchConversation, ConversationSearchIndex>{};
  bool _loading = false;
  bool _stopped = false;
  int _read = 0;
  int _total = 0;

  /// Conversations are still being read.
  bool get loading => _loading;

  /// How far reading has come, 0 to 1.
  double get progress => _total == 0 ? 1 : _read / _total;

  /// Messages that can be found, in all conversations read so far.
  int get messageCount {
    int n = 0;
    for (final ConversationSearchIndex index in _indexes.values) {
      n += index.length;
    }
    return n;
  }

  /// Reads [conversations] (the newest first), calling [onProgress] after
  /// each one: results can be shown while the rest is read.
  Future<void> load(
    List<SearchConversation> conversations, {
    VoidCallback? onProgress,
  }) async {
    final List<SearchConversation> order =
        List<SearchConversation>.of(conversations)..sort(
          (SearchConversation a, SearchConversation b) =>
              b.lastAtMillis.compareTo(a.lastAtMillis),
        );
    _loading = true;
    _read = 0;
    _total = order.length;
    _indexes.clear();
    try {
      for (final SearchConversation c in order) {
        if (_stopped) {
          return;
        }
        final List<ChatMessage> thread = await store.load(c.storeKey);
        if (_stopped) {
          return;
        }
        final ConversationSearchIndex index = ConversationSearchIndex();
        await index.update(thread, hidden: hidden);
        if (_stopped) {
          return;
        }
        if (index.length > 0) {
          _indexes[c] = index;
        }
        _read++;
        onProgress?.call();
      }
    } finally {
      _loading = false;
    }
  }

  /// The conversations with messages [query] matches, the one with the
  /// newest match first.
  List<GlobalSearchGroup> search(
    SearchQuery query, {
    int perConversation = kGlobalSearchHitsPerConversation,
    int maxHits = kGlobalSearchMaxHits,
  }) {
    if (!query.searchesMessages) {
      return const <GlobalSearchGroup>[];
    }
    final List<_Matched> matched = <_Matched>[];
    for (final MapEntry<SearchConversation, ConversationSearchIndex> e
        in _indexes.entries) {
      final ConversationSearchIndex index = e.value;
      final List<int> found = <int>[];
      int total = 0;
      for (int i = index.length - 1; i >= 0; i--) {
        if (query.matchesFolded(index.foldedAt(i))) {
          total++;
          if (found.length < perConversation) {
            found.add(i);
          }
        }
      }
      if (total > 0) {
        matched.add(_Matched(e.key, index, found, total));
      }
    }
    matched.sort((_Matched a, _Matched b) => b.newest.compareTo(a.newest));
    final List<GlobalSearchGroup> groups = <GlobalSearchGroup>[];
    int listed = 0;
    for (final _Matched m in matched) {
      if (listed >= maxHits) {
        break;
      }
      final List<GlobalSearchHit> hits = <GlobalSearchHit>[];
      for (final int i in m.found) {
        if (listed >= maxHits) {
          break;
        }
        final ({String text, List<SearchRange> ranges}) snippet = searchSnippet(
          m.index.textAt(i),
          query,
        );
        hits.add(
          GlobalSearchHit(
            messageId: m.index.idAt(i),
            sentAtMillis: m.index.timeAt(i),
            snippet: snippet.text,
            ranges: snippet.ranges,
          ),
        );
        listed++;
      }
      groups.add(
        GlobalSearchGroup(conversation: m.c, hits: hits, total: m.total),
      );
    }
    return groups;
  }

  /// Stops reading and forgets everything read.
  void dispose() {
    _stopped = true;
    _indexes.clear();
  }
}

/// A conversation with matches, while results are put together.
final class _Matched {
  _Matched(this.c, this.index, this.found, this.total);

  final SearchConversation c;
  final ConversationSearchIndex index;

  /// Positions in [index], newest first.
  final List<int> found;
  final int total;

  int get newest => index.timeAt(found.first);
}
