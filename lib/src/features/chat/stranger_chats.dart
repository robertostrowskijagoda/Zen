import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/intro/gate_route.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_gate_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Messages to people who are not friends, in the ordinary chats
// (consent is the currency). Anyone may write first, but:
//  - each message carries the sender's mini-profile (name and photo),
//    so the person written to sees who it is;
//  - until the other side answers, at most [kStrangerMessagesBeforeReply]
//    messages go (the sender's app counts, the receiver's app checks
//    again), text only, each at most [kMaxStrangerMessageChars];
//  - the person written to decides who may write first at all
//    ([StrangerMessagesFrom], by default friends of friends) and what a
//    first message costs ([StrangerChatBook.price], pyramid points; 0 =
//    free). The price is paid once per first contact, not per message:
//    after it the usual limit of [kStrangerMessagesBeforeReply] messages
//    before an answer holds, and an answer opens the conversation — a price
//    per message would make every unanswered line cost, while the price is
//    there to keep unwanted first contacts away;
//  - someone a friend opened a gate to this person for (an introduction,
//    see meet/intro/) may write first whatever the settings, as may
//    someone who paid the price;
//  - a message request is answered by writing back, inviting to friends,
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

/// How long a gate or a paid first message lets someone start a
/// conversation (and lets this person start one).
const Duration kStrangerPassLife = Duration(days: 30);

/// Passes kept at most (each way).
const int kMaxStrangerPasses = 300;

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

/// Someone may start a conversation outside friends: a friend's gate
/// opened the way ([via]), or the first message was paid ([paid]).
@immutable
final class StrangerPass {
  const StrangerPass({required this.at, this.paid = false, this.via = ''});

  final int at;
  final bool paid;

  /// The friend whose gate it was ('' when paid).
  final String via;

  bool aliveAt(int now) => now - at < kStrangerPassLife.inMilliseconds;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'at': at,
    if (paid) 'p': true,
    if (via.isNotEmpty) 'v': via,
  };

  static StrangerPass? fromJson(Object? json) {
    if (json is! Map || json['at'] is! int) {
      return null;
    }
    final Object? v = json['v'];
    return StrangerPass(
      at: json['at'] as int,
      paid: json['p'] == true,
      via: v is String && v.length <= 64 ? v : '',
    );
  }
}

/// Why a message to someone who is not a friend cannot go now.
final class StrangerMessageRefused implements Exception {
  const StrangerMessageRefused(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The conversations with people who are not friends, who may start
/// one and what a first message costs (see the top of this file).
final class StrangerChatBook extends ChangeNotifier implements ContactPasses {
  StrangerChatBook({
    required this.disk,
    this.isFriendOfFriend,
    this.ownMiniProfile,
    this.termsOf,
    this.invited,
    this.onPriceChanged,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerDisk disk;

  /// Whether some friend of this person has [address] among their friends
  /// (from the friend lists friends share). Null: never.
  final bool Function(String address)? isFriendOfFriend;

  /// This person's mini-profile, as it goes with their messages to
  /// people who are not friends.
  final MiniProfileTag? Function()? ownMiniProfile;

  /// What writing first to [address] takes, as this phone can tell (their
  /// published price, or closed). Null: never known.
  final DirectTerms Function(String address)? termsOf;

  /// Whether a friend invitation waits between this person and [address],
  /// either way: they may write to each other before it is answered (to
  /// tell who they are), with no first-contact terms and no reply limits.
  /// Null: never. Set by the social hub (it knows the invitations).
  bool Function(String address)? invited;

  /// This person changed who may write first or the price (to publish it).
  final VoidCallback? onPriceChanged;

  final int Function() _now;
  static const String _key = 'chat/strangers';

  final Map<String, StrangerChat> _chats = <String, StrangerChat>{};
  final List<int> _firstContacts = <int>[];
  StrangerMessagesFrom _from = StrangerMessagesFrom.friendsOfFriends;
  int _price = 0;

  /// Who may start a conversation with this person (gates, paid).
  final Map<String, StrangerPass> _passesIn = <String, StrangerPass>{};

  /// Whom this person may start one with (gates opened, paid).
  final Map<String, StrangerPass> _passesOut = <String, StrangerPass>{};
  Future<void>? _loading;

  StrangerMessagesFrom get from => _from;

  /// What a first message from someone who is not a friend costs
  /// (hundredths of a pyramid point; 0 = free).
  int get price => _price;

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
      final Object? price = json['price'];
      _price = price is int && price >= 0 && price <= kGateMaxPrice ? price : 0;
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
      void passes(Object? from, Map<String, StrangerPass> into) {
        if (from is! Map) {
          return;
        }
        for (final MapEntry<dynamic, dynamic> e in from.entries.take(
          kMaxStrangerPasses,
        )) {
          final StrangerPass? p = StrangerPass.fromJson(e.value);
          if (e.key is String && p != null) {
            into[_n(e.key as String)] = p;
          }
        }
      }

      passes(json['in'], _passesIn);
      passes(json['out'], _passesOut);
    } on Object catch (error, stack) {
      logZenError('Rozmowy z nieznajomymi: odczyt', error, stack);
    }
    notifyListeners();
  }

  Future<void> _save() async {
    notifyListeners();
    final int now = _now();
    for (final Map<String, StrangerPass> m in <Map<String, StrangerPass>>[
      _passesIn,
      _passesOut,
    ]) {
      m.removeWhere((String _, StrangerPass p) => !p.aliveAt(now));
      while (m.length > kMaxStrangerPasses) {
        m.remove(
          m.entries
              .reduce(
                (
                  MapEntry<String, StrangerPass> a,
                  MapEntry<String, StrangerPass> b,
                ) => a.value.at <= b.value.at ? a : b,
              )
              .key,
        );
      }
    }
    try {
      await disk.write(
        _key,
        Uint8List.fromList(
          utf8.encode(
            jsonEncode(<String, dynamic>{
              'from': _from.name,
              if (_price > 0) 'price': _price,
              // The day's budget of new strangers survives a restart.
              'first': _firstContacts,
              'chats': <Map<String, dynamic>>[
                for (final StrangerChat c in _chats.values) c.toJson(),
              ],
              if (_passesIn.isNotEmpty)
                'in': <String, dynamic>{
                  for (final MapEntry<String, StrangerPass> e
                      in _passesIn.entries)
                    e.key: e.value.toJson(),
                },
              if (_passesOut.isNotEmpty)
                'out': <String, dynamic>{
                  for (final MapEntry<String, StrangerPass> e
                      in _passesOut.entries)
                    e.key: e.value.toJson(),
                },
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
    onPriceChanged?.call();
  }

  /// Sets the price of a first message ([value] hundredths; 0 = free).
  Future<void> setPrice(int value) async {
    await load();
    _price = value.clamp(0, kGateMaxPrice);
    await _save();
    onPriceChanged?.call();
  }

  /// Whom [address] got in through ([StrangerPass]), if they may start a
  /// conversation with this person now.
  StrangerPass? passFrom(String address) {
    final StrangerPass? p = _passesIn[_n(address)];
    return p != null && p.aliveAt(_now()) ? p : null;
  }

  /// Whether this person may start a conversation with [address] now
  /// whatever their settings say (a gate opened to them, or paid).
  StrangerPass? passTo(String address) {
    final StrangerPass? p = _passesOut[_n(address)];
    return p != null && p.aliveAt(_now()) ? p : null;
  }

  @override
  Future<void> letIn(
    String address, {
    required bool paid,
    String via = '',
  }) async {
    await load();
    _passesIn[_n(address)] = StrangerPass(
      at: _now(),
      paid: paid,
      via: via.isEmpty ? '' : _n(via),
    );
    await _save();
  }

  @override
  Future<void> mayWrite(String address, {required bool paid}) async {
    await load();
    _passesOut[_n(address)] = StrangerPass(at: _now(), paid: paid);
    await _save();
  }

  @override
  int? priceFrom(String address) => switch (_from) {
    StrangerMessagesFrom.nobody => null,
    StrangerMessagesFrom.friendsOfFriends =>
      (isFriendOfFriend?.call(address) ?? false) ? _price : null,
    StrangerMessagesFrom.everyone => _price,
  };

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
    if (invited?.call(address) ?? false) {
      return null;
    }
    final StrangerChat? chat = chatWith(address);
    if (chat == null && passTo(address) == null) {
      // A first contact: their settings, as far as this phone knows them.
      final DirectTerms terms =
          termsOf?.call(address) ?? const DirectTerms.unknown();
      if (terms.known && terms.closed) {
        return t(
          'Ta osoba nie przyjmuje pierwszych wiadomości od Ciebie. '
          'Spróbuj przez bramy znajomych („Poproś o przedstawienie”).',
        );
      }
      if (terms.known && terms.price > 0) {
        return t(
          'Pierwsza wiadomość do tej osoby kosztuje {price}. Zapłać '
          'w grafie („Poproś o przedstawienie” → „Bezpośrednio”) albo '
          'otwórz bramę przez znajomych.',
          <String, Object?>{'price': formatPoints(terms.price)},
        );
      }
    }
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
    if (invited?.call(address) ?? false) {
      return true;
    }
    final StrangerChat? chat = chatWith(address);
    if (chat == null) {
      // Introduced through a friend's gate, or paid: in, whatever the
      // settings and the day's budget say.
      if (passFrom(address) != null) {
        return true;
      }
      final int t = _now();
      _firstContacts.removeWhere((int at) => t - at > 24 * 3600 * 1000);
      final int? asked = priceFrom(address);
      return asked == 0 && _firstContacts.length < kStrangerFirstContactsPerDay;
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
    if (chat == null && passFrom(a) == null && !(invited?.call(a) ?? false)) {
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

/// The conversations with people who are not friends.
final Provider<StrangerChatBook> strangerChatsProvider =
    Provider<StrangerChatBook>((Ref ref) {
      // The pyramid only while it is switched on and already started.
      PyramidService? pyramid() =>
          ref.read(featureFlagsProvider).isEnabled(ZenFeature.pyramid) &&
              ref.exists(pyramidServiceProvider)
          ? ref.read(pyramidServiceProvider)
          : null;
      late final StrangerChatBook book;
      book = StrangerChatBook(
        disk: ref.read(ledgerDiskProvider),
        // Friends of friends, as far as friends share their lists.
        isFriendOfFriend: (String address) =>
            ref.read(meetServiceProvider).mutualFriends(address).isNotEmpty,
        ownMiniProfile: () {
          final LedgerNode? node = ref.read(ledgerNodeProvider);
          return node != null && node.isReady ? ownMiniProfile(node) : null;
        },
        // Members publish their first-message price in the pyramid.
        termsOf: (String address) => pyramidMessageTerms(pyramid(), address),
        onPriceChanged: () => unawaitedLogged(
          syncMessagePrice(pyramid(), strangerPriceLevels(book)),
          context: 'First message price',
        ),
      );
      unawaitedLogged(book.load(), context: 'Rozmowy z nieznajomymi');
      ref.onDispose(book.dispose);
      return book;
    });

/// [book]'s settings as the pyramid's price list carries them.
Map<String, int> strangerPriceLevels(StrangerChatBook book) =>
    messagePriceLevels(
      fof: book.from != StrangerMessagesFrom.nobody,
      strangers: book.from == StrangerMessagesFrom.everyone,
      price: book.price,
    );
