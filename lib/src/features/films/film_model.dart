import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/media/video_compressor.dart';

// Short films ("Filmy"): what they are in the ledger.
//
// A film is an entry of its own kind (`film`) in the author's `feed/<account>`
// space, sealed for its audience like a post. The film itself is an encrypted
// blob (see `post_media.dart`); the entry lists no blobs on purpose, so
// friends' phones do not download every film on their own: the "Filmy"
// section fetches what is about to play (film_delivery.dart).
//
// Reactions are entries of the viewer's `acts/<account>`, like on the wall:
// likes (`like`) and comments (`comment`) as they are, plus a reaction
// (`film_react`), the films watched (`film_seen`, which the author counts)
// and films passed on to friends of friends (`film_pass`).

/// Entry kind of a film in a `feed/<account>` space. It is removed with a
/// `post_del` naming it, like a post.
const String kFilmKind = 'film';

/// Entry kind of an emoji reaction to a film (`acts/<account>`): the
/// latest one per film wins, an empty one takes it back.
const String kFilmReactionKind = 'film_react';

/// Entry kind of films watched (`acts/<account>`): `posts` lists film ids.
const String kFilmSeenKind = 'film_seen';

/// Entry kind of a public film passed on to the passer's friends (friends
/// of the author who may watch it when they opt in): the signed film with
/// its certificate, as a reshare carries a post.
const String kFilmPassKind = 'film_pass';

/// Longest caption of a film.
const int kMaxFilmCaptionChars = 150;

/// A film is recorded up to this long by default.
const int kFilmDefaultMaxMs = 60 * 1000;

/// And never longer than this.
const int kFilmHardMaxMs = 90 * 1000;

/// The shortest film worth publishing.
const int kFilmMinMs = 1000;

/// Largest film accepted (what a friend's mailbox holds for one sender).
const int kFilmMaxBytes = kCompressedVideoMaxBytes;

/// Film ids at most in one `film_seen` entry.
const int kMaxSeenPerEntry = 64;

/// The reactions offered under a film (the heart is the like).
const List<String> kFilmReactions = <String>[
  '😂',
  '😍',
  '🔥',
  '😮',
  '😢',
  '👏',
];

/// The film a film answers ("odpowiedź filmem").
@immutable
final class FilmReplyRef {
  const FilmReplyRef({required this.id, required this.account});

  final String id;

  /// Whose film it answers.
  final String account;

  Map<String, dynamic> toJson() => <String, dynamic>{'id': id, 'a': account};

  static FilmReplyRef? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? account = json['a'];
    if (id is! String ||
        account is! String ||
        id.isEmpty ||
        id.length > 128 ||
        account.isEmpty ||
        account.length > 128) {
      return null;
    }
    return FilmReplyRef(id: id, account: account);
  }

  @override
  bool operator ==(Object other) =>
      other is FilmReplyRef && other.id == id && other.account == account;

  @override
  int get hashCode => Object.hash(id, account);
}

/// The caption trimmed and checked; throws [ArgumentError] when too long.
String checkedFilmCaption(String caption) {
  final String trimmed = caption.trim();
  if (trimmed.length > kMaxFilmCaptionChars) {
    throw ArgumentError(
      tn(
        kMaxFilmCaptionChars,
        one: 'Opis jest za długi (maks. {n} znak).',
        few: 'Opis jest za długi (maks. {n} znaki).',
        many: 'Opis jest za długi (maks. {n} znaków).',
      ),
    );
  }
  return trimmed;
}

/// Body of a new film (validated): [video] and [poster] are references from
/// `storeMedia`. Anything but a public film is then sealed with
/// `LedgerNode.seal` before it is written.
Map<String, dynamic> newFilmBody({
  required Map<String, dynamic> video,
  String caption = '',
  Audience audience = Audience.all,
  Map<String, dynamic>? poster,
  FilmReplyRef? replyTo,
  int width = 0,
  int height = 0,
}) {
  final String cap = checkedFilmCaption(caption);
  final MediaRef? ref = mediaRefFromJson(video);
  if (ref == null || !isVideoMime(ref.mime)) {
    throw ArgumentError(t('To nie jest film.'));
  }
  final int? ms = ref.durationMs;
  if (ms != null && ms > kFilmHardMaxMs + 1000) {
    throw ArgumentError(
      tn(
        kFilmHardMaxMs ~/ 1000,
        one: 'Film jest za długi (maks. {n} sekunda).',
        few: 'Film jest za długi (maks. {n} sekundy).',
        many: 'Film jest za długi (maks. {n} sekund).',
      ),
    );
  }
  return <String, dynamic>{
    'cap': cap,
    'aud': audience.name,
    'vid': video,
    'pst': ?poster,
    if (replyTo != null) 're': replyTo.toJson(),
    if (width > 0 && height > 0) ...<String, dynamic>{'w': width, 'h': height},
  };
}

/// Body of a reaction to [filmId] ([emoji] empty takes it back).
Map<String, dynamic> filmReactionBody(String filmId, String emoji) {
  if (emoji.isNotEmpty && !kFilmReactions.contains(emoji)) {
    throw ArgumentError.value(emoji, 'emoji');
  }
  return <String, dynamic>{'post': filmId, 'e': emoji};
}

/// Bodies of `film_seen` entries for [filmIds] (at most
/// [kMaxSeenPerEntry] ids each).
List<Map<String, dynamic>> filmSeenBodies(Iterable<String> filmIds) {
  final List<String> ids = filmIds.toSet().toList();
  return <Map<String, dynamic>>[
    for (int i = 0; i < ids.length; i += kMaxSeenPerEntry)
      <String, dynamic>{
        'posts': ids.sublist(
          i,
          i + kMaxSeenPerEntry < ids.length ? i + kMaxSeenPerEntry : ids.length,
        ),
      },
  ];
}

/// Film ids [acts] (of one account) say were watched.
Set<String> seenFilms(Iterable<LogEntry> acts) => <String>{
  for (final LogEntry e in acts)
    if (e.kind == kFilmSeenKind && e.body['posts'] is List)
      for (final Object? id in (e.body['posts'] as List).take(kMaxSeenPerEntry))
        if (id is String) id,
};

/// The reaction of one account per film in [acts], latest entry winning
/// (taken-back ones left out).
Map<String, String> filmReactionsOf(Iterable<LogEntry> acts) {
  final Map<String, (int, String)> latest = <String, (int, String)>{};
  for (final LogEntry e in acts) {
    final Object? post = e.body['post'];
    final Object? emoji = e.body['e'];
    if (e.kind != kFilmReactionKind || post is! String || emoji is! String) {
      continue;
    }
    final int at = e.hlc.toInt();
    final (int, String)? had = latest[post];
    if (had == null || at >= had.$1) {
      latest[post] = (at, emoji);
    }
  }
  return <String, String>{
    for (final MapEntry<String, (int, String)> m in latest.entries)
      if (kFilmReactions.contains(m.value.$2)) m.key: m.value.$2,
  };
}

/// One film as the "Filmy" section shows it.
@immutable
final class FilmPost {
  const FilmPost({
    required this.id,
    required this.account,
    required this.authorLabel,
    required this.video,
    required this.millis,
    required this.isOwn,
    this.caption = '',
    this.poster,
    this.audience = Audience.all,
    this.replyTo,
    this.entry,
    this.authorAddress = '',
    this.close = false,
    this.passedBy = const <String>[],
    this.passerAddresses = const <String>[],
    this.likes = const <FeedLiker>[],
    this.likedByMe = false,
    this.comments = const <FeedComment>[],
    this.reactions = const <String, int>{},
    this.myReaction = '',
    this.views = 0,
    this.replies = const <String>[],
    this.width = 0,
    this.height = 0,
  });

  final String id;
  final String account;
  final String authorLabel;
  final String caption;
  final int millis;
  final bool isOwn;
  final MediaRef video;
  final MediaRef? poster;
  final Audience audience;

  /// The film this one answers.
  final FilmReplyRef? replyTo;

  /// The signed film (what reports and passes carry).
  final LogEntry? entry;

  /// The author's device address ('' for a friend of a friend whose
  /// address is not known).
  final String authorAddress;

  /// From a close friend ("przyjaciel").
  final bool close;

  /// Friends who passed this film on (a friend of a friend's film); empty
  /// for friends' own films.
  final List<String> passedBy;

  /// Their addresses (they have watched it, so they may have the film).
  final List<String> passerAddresses;

  /// Who likes it: this account and friends.
  final List<FeedLiker> likes;
  final bool likedByMe;

  /// Oldest first.
  final List<FeedComment> comments;

  /// Emoji → how many reacted so.
  final Map<String, int> reactions;

  /// This account's reaction ('' for none).
  final String myReaction;

  /// How many friends watched it (only counted for the author's own films).
  final int views;

  /// Ids of the films answering this one.
  final List<String> replies;

  /// The picture size when the author's phone knew it (0: unknown).
  final int width;
  final int height;

  bool get fromFriendOfFriend => passedBy.isNotEmpty;

  int get likeCount => likes.length;

  int get commentCount =>
      comments.where((FeedComment c) => !c.hiddenByAuthor).length;

  /// Blob ids of the film and its poster.
  List<String> get blobIds => <String>[video.id, ?poster?.id];

  FilmPost copyWith({
    List<FeedLiker>? likes,
    bool? likedByMe,
    List<FeedComment>? comments,
    Map<String, int>? reactions,
    String? myReaction,
    int? views,
    List<String>? replies,
    List<String>? passedBy,
    List<String>? passerAddresses,
    String? authorLabel,
    String? authorAddress,
    bool? close,
  }) => FilmPost(
    id: id,
    account: account,
    authorLabel: authorLabel ?? this.authorLabel,
    video: video,
    millis: millis,
    isOwn: isOwn,
    caption: caption,
    poster: poster,
    audience: audience,
    replyTo: replyTo,
    entry: entry,
    authorAddress: authorAddress ?? this.authorAddress,
    close: close ?? this.close,
    passedBy: passedBy ?? this.passedBy,
    passerAddresses: passerAddresses ?? this.passerAddresses,
    likes: likes ?? this.likes,
    likedByMe: likedByMe ?? this.likedByMe,
    comments: comments ?? this.comments,
    reactions: reactions ?? this.reactions,
    myReaction: myReaction ?? this.myReaction,
    views: views ?? this.views,
    replies: replies ?? this.replies,
    width: width,
    height: height,
  );
}

/// [entry] (with its readable [body]) as a film, or `null` when it is not
/// one or does not add up.
FilmPost? filmFromEntry(
  LogEntry entry,
  Map<String, dynamic> body, {
  required bool isOwn,
  required String authorLabel,
  String authorAddress = '',
  bool close = false,
}) {
  if (entry.kind != kFilmKind) {
    return null;
  }
  final MediaRef? video = mediaRefFromJson(body['vid']);
  if (video == null || !isVideoMime(video.mime)) {
    return null;
  }
  final MediaRef? poster = mediaRefFromJson(body['pst']);
  final Object? cap = body['cap'];
  final String caption = cap is String
      ? (cap.length > kMaxFilmCaptionChars
            ? cap.substring(0, kMaxFilmCaptionChars)
            : cap)
      : '';
  final Object? w = body['w'];
  final Object? h = body['h'];
  return FilmPost(
    id: entry.id,
    account: entry.account,
    authorLabel: authorLabel,
    video: video,
    poster: poster != null && isPhotoMime(poster.mime) ? poster : null,
    millis: entry.hlc.millis,
    isOwn: isOwn,
    caption: caption,
    audience: audienceByName(body['aud']) ?? Audience.public,
    replyTo: FilmReplyRef.fromJson(body['re']),
    entry: entry,
    authorAddress: authorAddress,
    close: close,
    width: w is int && w > 0 && w < 10000 ? w : 0,
    height: h is int && h > 0 && h < 10000 ? h : 0,
  );
}
