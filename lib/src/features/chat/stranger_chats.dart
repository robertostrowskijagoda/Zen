import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Messages to people who are not friends, in the ordinary chats (§13,
// §24.1: consent is the currency). Anyone may write first, but:
//  - each message carries the sender's mini-profile (§9: name and photo),
//    so the person written to sees who it is;
//  - until the other side answers, at most [kStrangerMessagesBeforeReply]
//    messages go (the sender's app counts, the receiver's app checks
//    again), text only, each at most [kMaxStrangerMessageChars];
//  - the person written to decides who may write first at all
//    ([StrangerMessagesFrom], by default friends of friends), and a
//    message request is answered by writing back, inviting to friends,
//    ignoring it or blocking the person.
// Once both sides wrote, the conversation is open (still text only: files
// and calls stay between friends).

/// Messages one side may send before the other answers.
const int kStrangerMessagesBeforeReply = 3;

/// Longest message to or from someone who is not a friend.
const int kMaxStrangerMessageChars = 1000;

/// Conversations with people who are not friends kept at most; past it the
/// oldest unanswered request goes.
const int kMaxStrangerChats = 50;

/// New people who may start a conversation with this person in a day.
const int kStrangerFirstContactsPerDay = 20;

/// Who may write first without being a friend.
enum StrangerMessagesFrom {
  nobody,
  friendsOfFriends,
  everyone;

  String get label => switch (this) {
    StrangerMessagesFrom.nobody => t('Nikt'),
    StrangerMessagesFrom.friendsOfFriends => t('Znajomi znajomych'),
    StrangerMessagesFrom.everyone => t('Każdy'),
  };
}

/// One conversation with someone who is not a friend.
@immutable
final class StrangerChat {
  const StrangerChat({
    required this.address,
    required this.name,
    required this.lastAt,
    this.avatar,
    this.preview = '',
    this.theyStarted = false,
    this.open = false,
    this.sentUnanswered = 0,
    this.receivedUnanswered = 0,
    this.unread = 0,
  });

  static StrangerChat? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? address = json['a'];
    final Object? at = json['at'];
    if (address is! String || address.isEmpty || at is! int) {
      return null;
    }
    int count(String key) => json[key] is int ? json[key] as int : 0;
    return StrangerChat(
      address: address,
      name: json['n'] is String ? json['n'] as String : '',
      avatar: json['av'] is Map
          ? Map<String, dynamic>.from(json['av'] as Map)
          : null,
      lastAt: at,
      preview: json['p'] is String ? json['p'] as String : '',
      theyStarted: json['in'] == true,
      open: json['o'] == true,
      sentUnanswered: count('s'),
      receivedUnanswered: count('r'),
      unread: count('u'),
    );
  }

  final String address;

  /// The name from their mini-profile ('' while they have not written).
  final String name;

  /// The photo reference of their mini-profile.
  final Map<String, dynamic>? avatar;
  final int lastAt;
  final String preview;

  /// They wrote first: a message request until this person answers.
  final bool theyStarted;

  /// Both sides wrote: no more limits on the number of messages.
  final bool open;

  /// Messages this person sent since the other side last wrote.
  final int sentUnanswered;

  /// Messages they sent since this person last wrote.
  final int receivedUnanswered;
  final int unread;

  /// A message request waiting for this person's answer.
  bool get isRequest => theyStarted && !open;

  /// The name to show.
  String get shownName => name.trim().isEmpty ? t('Kontakt Zen') : name.trim();

  StrangerChat copyWith({
    String? name,
    Map<String, dynamic>? avatar,
    int? lastAt,
    String? preview,
    bool? open,
    int? sentUnanswered,
    int? receivedUnanswered,
    int? unread,
  }) => StrangerChat(
    address: address,
    name: name ?? this.name,
    avatar: avatar ?? this.avatar,
    lastAt: lastAt ?? this.lastAt,
    preview: preview ?? this.preview,
    theyStarted: theyStarted,
    open: open ?? this.open,
    sentUnanswered: sentUnanswered ?? this.sentUnanswered,
    receivedUnanswered: receivedUnanswered ?? this.receivedUnanswered,
    unread: unread ?? this.unread,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'a': address,
    if (name.isNotEmpty) 'n': name,
    'av': ?avatar,
    'at': lastAt,
    if (preview.isNotEmpty) 'p': preview,
    if (theyStarted) 'in': true,
    if (open) 'o': true,
    if (sentUnanswered > 0) 's': sentUnanswered,
    if (receivedUnanswered > 0) 'r': receivedUnanswered,
    if (unread > 0) 'u': unread,
  };
}

/// Why a message to someone who is not a friend cannot go now.
final class StrangerMessageRefused implements Exception {
  const StrangerMessageRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The conversations with people who are not friends, and who may start
/// one (see the top of this file).
final class StrangerChatBook extends ChangeNotifier {
  StrangerChatBook({
    required this.disk,
    this.isFriendOfFriend,
    this.ownMiniProfile,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerDisk disk;

  /// Whether some friend of this person has [address] among their friends
  /// (from the friend lists friends share). Null: never.
  final bool Function(String address)? isFriendOfFriend;

  /// This person's mini-profile (§9), as it goes with their messages to
  /// people who are not friends.
  final MiniProfileTag? Function()? ownMiniProfile;

  final int Function() _now;
  static const String _key = 'chat/strangers';

  final Map<String, StrangerChat> _chats = <String, StrangerChat>{};
  final List<int> _firstContacts = <int>[];
  StrangerMessagesFrom _from = StrangerMessagesFrom.friendsOfFriends;
  Future<void>? _loading;

  StrangerMessagesFrom get from => _from;

  String _n(String address) => PeerShareCodec.normalizeAddress(address);

  /// Reads the book (once; later calls wait for the same read).
  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      final Uint8List? raw = await disk.read(_key);
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return;
      }
      _from = StrangerMessagesFrom.values.firstWhere(
        (StrangerMessagesFrom f) => f.name == json['from'],
        orElse: () => StrangerMessagesFrom.friendsOfFriends,
      );
      final Object? firsts = json['first'];
      if (firsts is List) {
        _firstContacts
          ..clear()
          ..addAll(firsts.whereType<int>().take(kStrangerFirstContactsPerDay));
      }
      final Object? chats = json['chats'];
      if (chats is List) {
        for (final Object? c in chats) {
          final StrangerChat? chat = StrangerChat.fromJson(c);
          if (chat != null) {
            _chats[_n(chat.address)] = chat;
          }
        }
      }
    } on Object catch (error, stack) {
      logZenError('Rozmowy z nieznajomymi: odczyt', error, stack);
    }
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    try {
      await disk.write(
        _key,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'from': _from.name,
              // The day's budget of new strangers survives a restart.
              'first': _firstContacts,
              'chats': <Map<String, dynamic>>[
                for (final StrangerChat c in _chats.values) c.toJson(),
              ],
            }),
          ),
        ),
      );
    } on Object catch (error, stack) {
      logZenError('Rozmowy z nieznajomymi: zapis', error, stack);
    }
  }

  /// The conversation with [address], if there is one.
  StrangerChat? chatWith(String address) => _chats[_n(address)];

  /// Message requests waiting for this person's answer, newest first.
  List<StrangerChat> get requests =>
      _chats.values.where((StrangerChat c) => c.isRequest).toList()..sort(
        (StrangerChat a, StrangerChat b) => b.lastAt.compareTo(a.lastAt),
      );

  /// The other conversations (this person wrote first, or both did),
  /// newest first.
  List<StrangerChat> get conversations =>
      _chats.values.where((StrangerChat c) => !c.isRequest).toList()..sort(
        (StrangerChat a, StrangerChat b) => b.lastAt.compareTo(a.lastAt),
      );

  Future<void> setFrom(StrangerMessagesFrom value) async {
    await load();
    _from = value;
    await _save();
  }

  /// Why this person cannot write to [address] now, or `null` when they
  /// can ([text] is what they want to send).
  String? refusalToSend(String address, String text) {
    if (text.length > kMaxStrangerMessageChars) {
      return t(
        'Wiadomość do osoby spoza znajomych może mieć najwyżej {n} '
        'znaków.',
        <String, Object?>{'n': kMaxStrangerMessageChars},
      );
    }
    final StrangerChat? chat = chatWith(address);
    if (chat != null &&
        !chat.open &&
        !chat.theyStarted &&
        chat.sentUnanswered >= kStrangerMessagesBeforeReply) {
      return t(
        'Poczekaj na odpowiedź: bez niej do osoby spoza znajomych '
        'idą najwyżej {n} wiadomości.',
        <String, Object?>{'n': kStrangerMessagesBeforeReply},
      );
    }
    return null;
  }

  /// This person wrote [text] to [address].
  Future<void> noteSent(String address, String text, {String name = ''}) async {
    await load();
    final String a = _n(address);
    final StrangerChat? chat = _chats[a];
    final int at = _now();
    _chats[a] = chat == null
        ? StrangerChat(
            address: a,
            name: name,
            lastAt: at,
            preview: _preview(text),
            sentUnanswered: 1,
          )
        : chat.copyWith(
            lastAt: at,
            preview: _preview(text),
            // Writing back opens it.
            open: chat.open || chat.receivedUnanswered > 0,
            sentUnanswered: chat.sentUnanswered + 1,
            receivedUnanswered: 0,
            name: chat.name.isEmpty ? name : null,
          );
    _trim();
    await _save();
  }

  /// Whether a message from [address] (not a friend) may come in now.
  bool admits(String address) {
    final StrangerChat? chat = chatWith(address);
    if (chat == null) {
      final int t = _now();
      _firstContacts.removeWhere((int at) => t - at > 24 * 3600 * 1000);
      return switch (_from) {
            StrangerMessagesFrom.nobody => false,
            StrangerMessagesFrom.friendsOfFriends =>
              isFriendOfFriend?.call(address) ?? false,
            StrangerMessagesFrom.everyone => true,
          } &&
          _firstContacts.length < kStrangerFirstContactsPerDay;
    }
    // An answer to this person's own message always comes in.
    return chat.open ||
        chat.sentUnanswered > 0 ||
        chat.receivedUnanswered < kStrangerMessagesBeforeReply;
  }

  /// A message [text] from [address] (not a friend) that [admits] let in,
  /// with their mini-profile.
  Future<void> noteReceived(
    String address,
    String text, {
    required MiniProfileTag mini,
    bool read = false,
  }) async {
    await load();
    final String a = _n(address);
    final StrangerChat? chat = _chats[a];
    final int at = _now();
    if (chat == null) {
      _firstContacts.add(at);
    }
    _chats[a] = chat == null
        ? StrangerChat(
            address: a,
            name: mini.name,
            avatar: mini.toJson()['av'] as Map<String, dynamic>?,
            lastAt: at,
            preview: _preview(text),
            theyStarted: true,
            receivedUnanswered: 1,
            unread: read ? 0 : 1,
          )
        : chat.copyWith(
            name: mini.name.isEmpty ? null : mini.name,
            lastAt: at,
            preview: _preview(text),
            // Their answer opens it.
            open: chat.open || chat.sentUnanswered > 0,
            sentUnanswered: 0,
            receivedUnanswered: chat.receivedUnanswered + 1,
            unread: read ? 0 : chat.unread + 1,
          );
    _trim();
    await _save();
  }

  /// The conversation with [address] was read.
  Future<void> markRead(String address) async {
    final StrangerChat? chat = chatWith(address);
    if (chat == null || chat.unread == 0) {
      return;
    }
    _chats[_n(address)] = chat.copyWith(unread: 0);
    await _save();
  }

  /// Drops the conversation with [address] (ignored, blocked, or they
  /// became a friend and it moves to the ordinary list).
  Future<void> forget(String address) async {
    await load();
    if (_chats.remove(_n(address)) != null) {
      await _save();
    }
  }

  void _trim() {
    while (_chats.length > kMaxStrangerChats) {
      final List<StrangerChat> byAge = _chats.values.toList()
        ..sort((StrangerChat a, StrangerChat b) {
          // Unanswered requests go first, oldest first.
          if (a.isRequest != b.isRequest) {
            return a.isRequest ? -1 : 1;
          }
          return a.lastAt.compareTo(b.lastAt);
        });
      _chats.remove(_n(byAge.first.address));
    }
  }

  static String _preview(String text) {
    final String line = text.trim().replaceAll('\n', ' ');
    return line.length > 120 ? line.substring(0, 120) : line;
  }
}

/// The conversations with people who are not friends (§13, §24.1).
final Provider<StrangerChatBook> strangerChatsProvider =
    Provider<StrangerChatBook>((Ref ref) {
      final StrangerChatBook book = StrangerChatBook(
        disk: ref.read(ledgerDiskProvider),
        // Friends of friends, as far as friends share their lists (§9).
        isFriendOfFriend: (String address) =>
            ref.read(meetServiceProvider).mutualFriends(address).isNotEmpty,
        ownMiniProfile: () {
          final LedgerNode? node = ref.read(ledgerNodeProvider);
          return node != null && node.isReady ? ownMiniProfile(node) : null;
        },
      );
      unawaitedLogged(book.load(), context: 'Rozmowy z nieznajomymi');
      ref.onDispose(book.dispose);
      return book;
    });
