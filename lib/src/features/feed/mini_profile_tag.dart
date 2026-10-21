import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

// The mini-profile that travels with likes and comments: name and
// profile photo, so someone who is not your friend is more than a bare name
// when their reaction reaches you through a friend. The tag is part of the
// signed like or comment, and the bundles that carry reactions along the
// reshare tree repeat it. The count "N wspólnych znajomych" is never sent: it
// is worked out on the receiving phone from the friend lists it can see.

/// Key of the tag inside the body of a like or a comment.
const String kMiniProfileKey = 'mp';

/// Key of the profile photo inside a bundle's liker or comment (`p`).
const String kBundleAvatarKey = 'p';

/// Bundle entries per page that carry a photo reference: it keeps a page of
/// 200 likers far below the size limit of an entry.
const int kMaxBundleAvatars = 40;

/// Name and photo of one account as it shows itself to people outside its
/// circle.
@immutable
final class MiniProfileTag {
  const MiniProfileTag({required this.name, this.avatar});

  /// Reads a tag from [json] (a body's `mp`), or `null` when there is
  /// nothing usable in it.
  static MiniProfileTag? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? name = json['n'];
    final String clipped = name is String ? _clip(name) : '';
    final MediaRef? avatar = mediaRefFromJson(json['av']);
    if (clipped.isEmpty && avatar == null) {
      return null;
    }
    return MiniProfileTag(name: clipped, avatar: avatar);
  }

  final String name;
  final MediaRef? avatar;

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (name.isNotEmpty) 'n': name,
    if (avatar != null) 'av': mediaRefToJson(avatar!),
  };

  static String _clip(String s) {
    final String trimmed = s.trim();
    return trimmed.length > kMaxProfileName
        ? trimmed.substring(0, kMaxProfileName)
        : trimmed;
  }
}

/// This account's own mini-profile, from its newest profile (`null` while
/// the profile has neither a name nor a photo).
MiniProfileTag? ownMiniProfile(LedgerNode node) {
  final LedgerProfile? profile = latestProfile(node, node.account);
  if (profile == null) {
    return null;
  }
  return MiniProfileTag.fromJson(
    MiniProfileTag(name: profile.name, avatar: profile.avatar).toJson(),
  );
}

/// [body] of a like or comment with [mini] attached (unchanged for `null`).
Map<String, dynamic> withMiniProfile(
  Map<String, dynamic> body,
  MiniProfileTag? mini,
) => mini == null
    ? body
    : <String, dynamic>{...body, kMiniProfileKey: mini.toJson()};

/// The photo of [account] as a reaction should carry it: the one in the
/// mini-profile the account attached to its own entry ([attached], the
/// entry's body), else the one from its newest profile entry.
Map<String, dynamic>? avatarJsonOf(
  LedgerNode node,
  String account,
  Map<String, dynamic>? attached,
) {
  final MiniProfileTag? tag = MiniProfileTag.fromJson(
    attached?[kMiniProfileKey],
  );
  if (tag?.avatar != null) {
    return mediaRefToJson(tag!.avatar!);
  }
  final MediaRef? avatar = latestProfile(node, account)?.avatar;
  return avatar == null ? null : mediaRefToJson(avatar);
}

/// How many friends of this account are also friends of [account], as far
/// as the friend lists shared with this phone say. [mutualByAddress] answers
/// for one mesh address (the meet service); every address known for the
/// account is tried and the largest answer wins.
int mutualFriendCount(
  LedgerNode node,
  String account,
  int Function(String address) mutualByAddress,
) {
  if (account.isEmpty || account == node.account) {
    return 0;
  }
  final Set<String> addresses = <String>{
    ...node.anyAddressesOf(account),
    ?latestProfile(node, account)?.address,
  }..remove('');
  int best = 0;
  for (final String address in addresses) {
    final int n = mutualByAddress(address);
    if (n > best) {
      best = n;
    }
  }
  return best;
}

/// "3 wspólnych znajomych"; `null` for none.
String? mutualFriendsText(int n) => n <= 0
    ? null
    : tn(
        n,
        one: '{n} wspólny znajomy',
        few: '{n} wspólnych znajomych',
        many: '{n} wspólnych znajomych',
      );
