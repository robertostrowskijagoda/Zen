import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/search/message_search.dart';
import 'package:zen/src/features/search/search_text.dart';

/// Most matches one conversation's search lists (the newest ones); the
/// count then reads "1000+".
const int kChatSearchMaxMatches = 1000;

/// Search inside one conversation (a chat with a friend or a group): the
/// words typed, the messages they match and which one is shown now.
///
/// Matches are counted from the newest: "1 z 12" is the newest one, the
/// arrow up goes to older ones. The screen listens and scrolls to
/// [currentId] each time [jumps] changes.
final class ChatSearchController extends ChangeNotifier {
  ChatSearchController({this.debounce = const Duration(milliseconds: 200)});

  /// How long typing has to pause before the conversation is searched.
  final Duration debounce;

  final ConversationSearchIndex _index = ConversationSearchIndex();
  bool _active = false;
  String _text = '';
  SearchQuery _query = SearchQuery.empty;

  /// Matches as positions in [_index], newest first.
  List<int> _found = const <int>[];
  Set<String> _foundIds = const <String>{};
  int _current = 0;
  bool _busy = false;
  int _jumps = 0;
  int _run = 0;
  Timer? _timer;
  bool _disposed = false;

  /// The message to stand at after the next search (opened at a result of
  /// the search on the chat list).
  String? _wanted;

  List<ChatMessage>? _thread;
  bool Function(ChatMessage message)? _hidden;
  Object? _hiddenVersion;
  bool _indexed = false;

  /// The search bar is open.
  bool get active => _active;

  /// What is in the field.
  String get text => _text;

  SearchQuery get query => _query;

  /// The search is running (the first index of a long history).
  bool get busy => _busy;

  /// How many messages match (at most [kChatSearchMaxMatches]).
  int get total => _found.length;

  /// There are more matches than are listed.
  bool get capped => _found.length >= kChatSearchMaxMatches;

  /// The match shown now, 1 for the newest; 0 when there is none.
  int get position => _found.isEmpty ? 0 : _current + 1;

  /// The message shown now.
  String? get currentId =>
      _found.isEmpty ? null : _index.idAt(_found[_current]);

  /// Whether the message [id] is one of the matches (its words are marked).
  bool isMatch(String id) => _foundIds.contains(id);

  /// Changes each time the screen should scroll to [currentId].
  int get jumps => _jumps;

  /// Ids of the matches, oldest first.
  List<String> get matchIds => <String>[
    for (int i = _found.length - 1; i >= 0; i--) _index.idAt(_found[i]),
  ];

  /// Opens the search bar; with [text] it searches at once and, with
  /// [at], stands at that message when it matches.
  void open({String text = '', String? at}) {
    _active = true;
    _wanted = at;
    _text = text;
    _query = SearchQuery.parse(text);
    _notify();
    if (_query.searchesMessages) {
      unawaited(_search());
    }
  }

  /// Closes the search bar and forgets what was found.
  void close() {
    _timer?.cancel();
    _run++;
    _active = false;
    _text = '';
    _query = SearchQuery.empty;
    _found = const <int>[];
    _foundIds = const <String>{};
    _current = 0;
    _busy = false;
    _wanted = null;
    _notify();
  }

  /// The field changed: searched again once typing pauses.
  void setText(String text) {
    if (text == _text) {
      return;
    }
    _text = text;
    final SearchQuery next = SearchQuery.parse(text);
    if (next == _query) {
      return;
    }
    _query = next;
    _timer?.cancel();
    if (!next.searchesMessages) {
      _run++;
      _found = const <int>[];
      _foundIds = const <String>{};
      _current = 0;
      _busy = false;
      _notify();
      return;
    }
    _timer = Timer(debounce, () => unawaited(_search()));
  }

  /// Searches now (Enter pressed before the pause ran out).
  void searchNow() {
    if (_timer?.isActive ?? false) {
      _timer!.cancel();
      unawaited(_search());
    }
  }

  /// The conversation as it is now (also each time a message comes or
  /// goes). While the bar is open the matches follow it and the one shown
  /// stays the same message. [hidden] leaves out what the person hid; it is
  /// taken again when [hiddenVersion] is another object.
  void updateThread(
    List<ChatMessage> thread, {
    bool Function(ChatMessage message)? hidden,
    Object? hiddenVersion,
  }) {
    if (identical(thread, _thread) &&
        identical(hiddenVersion, _hiddenVersion)) {
      return;
    }
    _thread = thread;
    _hidden = hidden;
    _hiddenVersion = hiddenVersion;
    _indexed = false;
    if (_active && _query.searchesMessages) {
      // Called while the screen is built: searched right after.
      scheduleMicrotask(() {
        if (!_disposed && identical(thread, _thread)) {
          unawaited(_search(keep: currentId));
        }
      });
    }
  }

  /// To the older match (the arrow up).
  void older() => _step(1);

  /// To the newer match (the arrow down).
  void newer() => _step(-1);

  void _step(int by) {
    if (_found.isEmpty) {
      return;
    }
    _current = (_current + by) % _found.length;
    _jumps++;
    _notify();
  }

  Future<void> _search({String? keep}) async {
    final int run = ++_run;
    final List<ChatMessage>? thread = _thread;
    if (thread == null) {
      return;
    }
    if (!_indexed) {
      _busy = true;
      _notify();
      await _index.update(thread, hidden: _hidden);
      if (run != _run || _disposed) {
        return;
      }
      _indexed = identical(thread, _thread);
    }
    final List<int> found = await _index.find(
      _query,
      limit: kChatSearchMaxMatches,
      cancelled: () => run != _run || _disposed,
    );
    if (run != _run || _disposed) {
      return;
    }
    final String? wanted = _wanted ?? keep;
    _wanted = null;
    final String? before = currentId;
    _found = found;
    _foundIds = <String>{for (final int i in found) _index.idAt(i)};
    int current = 0;
    if (wanted != null) {
      final int at = found.indexWhere((int i) => _index.idAt(i) == wanted);
      if (at >= 0) {
        current = at;
      }
    }
    _current = current;
    _busy = false;
    if (keep == null || currentId != before) {
      _jumps++;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
