import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart' show mediaIds;
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// Entry kind of photos and videos added to the profile's gallery (§9).
/// They live in the account's feed space (so friends get them the same
/// way), but they are not posts: the wall never shows them, and posts never
/// land in the gallery.
const String kGalleryKind = 'gallery';

/// Entry kind of a gallery item's removal.
const String kGalleryDeleteKind = 'gallery_del';

/// Photos and videos in one gallery entry.
const int kMaxGalleryBatch = 10;

/// Who sees gallery items, in the words of the gallery.
Map<Audience, String> get kGalleryAudienceLabels => <Audience, String>{
  Audience.public: t('Wszyscy (także obserwujący)'),
  Audience.all: t('Wszyscy znajomi'),
  Audience.mid: t('Znajomi i przyjaciele'),
  Audience.close: t('Tylko przyjaciele'),
};

Map<Audience, String> get kGalleryAudienceHints => <Audience, String>{
  Audience.public: t(
    'Znajomi i każdy, kto Cię obserwuje — także osoby spoza znajomych.',
  ),
  Audience.all: t('Wszyscy Twoi znajomi.'),
  Audience.mid: t('Znajomi oznaczeni jako „znajomi” i przyjaciele.'),
  Audience.close: t('Tylko najbliżsi, oznaczeni jako przyjaciele.'),
};

/// One addition to a gallery: what was added at once, for whom.
@immutable
final class GalleryItem {
  const GalleryItem({
    required this.id,
    required this.media,
    required this.millis,
    required this.audience,
    required this.entry,
  });

  final String id;
  final List<MediaRef> media;
  final int millis;
  final Audience audience;
  final LogEntry entry;
}

/// The body of a gallery entry (sealed for [audience] before publishing).
Map<String, dynamic> galleryBody(
  List<Map<String, dynamic>> media, {
  required Audience audience,
}) => <String, dynamic>{
  'v': 1,
  'img': media.take(kMaxGalleryBatch).toList(),
  'aud': audience.name,
};

/// The gallery of [account] (default: this account), newest first; only
/// what this device can open, without removed items.
List<GalleryItem> galleryOf(LedgerNode node, {String? account}) =>
    galleryFrom(node.entriesOf(ofAccount: account), bodyOf: node.bodyOf);

@visibleForTesting
List<GalleryItem> galleryFrom(
  Iterable<LogEntry> feed, {
  required Map<String, dynamic>? Function(LogEntry entry) bodyOf,
}) {
  final Set<String> removed = <String>{};
  final List<GalleryItem> items = <GalleryItem>[];
  for (final LogEntry e in feed) {
    if (e.kind == kGalleryDeleteKind) {
      final Object? target = bodyOf(e)?['item'];
      if (target is String) {
        removed.add(target);
      }
      continue;
    }
    if (e.kind != kGalleryKind) {
      continue;
    }
    final Map<String, dynamic>? b = bodyOf(e);
    final Object? img = b?['img'];
    if (img is! List) {
      continue;
    }
    final List<MediaRef> media = <MediaRef>[
      for (final Object? m in img.take(kMaxGalleryBatch)) ?mediaRefFromJson(m),
    ];
    if (media.isEmpty) {
      continue;
    }
    items.add(
      GalleryItem(
        id: e.id,
        media: media,
        millis: e.hlc.millis,
        audience: audienceByName(b!['aud']) ?? Audience.public,
        entry: e,
      ),
    );
  }
  return <GalleryItem>[
    for (final GalleryItem i in items)
      if (!removed.contains(i.id)) i,
  ]..sort((GalleryItem a, GalleryItem b) => b.millis.compareTo(a.millis));
}

/// Stores [media] (photos already sanitised) encrypted and adds them to this
/// account's gallery for [audience] — friends only unless chosen otherwise.
Future<void> addToGallery(
  LedgerNode node,
  List<({Uint8List bytes, String mime})> media, {
  Audience audience = Audience.all,
}) async {
  if (media.isEmpty) {
    return;
  }
  final List<Map<String, dynamic>> refs = <Map<String, dynamic>>[
    for (final ({Uint8List bytes, String mime}) m in media.take(
      kMaxGalleryBatch,
    ))
      await storeMedia(node.blobs, m.bytes, mime: m.mime),
  ];
  await node.publish(
    kGalleryKind,
    await node.seal(audience, galleryBody(refs, audience: audience)),
    blobs: mediaIds(refs),
  );
}

/// Removes a gallery item (a signed tombstone, like a removed post).
Future<void> removeFromGallery(LedgerNode node, String id) =>
    node.publish(kGalleryDeleteKind, <String, dynamic>{'v': 1, 'item': id});

/// Shows [item] to [audience] instead: the files are encrypted again with
/// fresh keys (so narrowing the audience does not leave the old keys
/// valid for new copies) and the old entry is removed.
Future<void> changeGalleryAudience(
  LedgerNode node,
  GalleryItem item,
  Audience audience,
) async {
  final List<({Uint8List bytes, String mime})> media =
      <({Uint8List bytes, String mime})>[];
  for (final MediaRef r in item.media) {
    final Uint8List? plain = await openMedia(node.blobs, r);
    if (plain == null) {
      throw StateError(t('plik jeszcze się nie pobrał'));
    }
    media.add((bytes: plain, mime: r.mime));
  }
  await addToGallery(node, media, audience: audience);
  await removeFromGallery(node, item.id);
}
