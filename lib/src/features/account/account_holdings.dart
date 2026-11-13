import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/passwords/password_entry.dart';

/// What the account on this device holds that the person made or received:
/// what would be lost if another account took its place here.
///
/// The one rule for all four ways another account can come onto a device
/// (a copy from another device, a backup file, a link, a key on paper or in
/// a file): a device that holds any of this is not fresh, and its account
/// is never replaced without the person's word ([isFresh]).
@immutable
final class AccountHoldings {
  const AccountHoldings({
    this.account = '',
    this.name = '',
    this.notes = 0,
    this.passwords = 0,
    this.posts = 0,
    this.chats = 0,
    this.invitations = 0,
    this.friends = 0,
    this.groups = 0,
    this.pyramid = false,
    this.dating = false,
    this.pebbles = 0,
    this.accountPassword = false,
  });

  /// The account (public key); empty when the device has none yet.
  final String account;

  /// The name the person set.
  final String name;
  final int notes;
  final int passwords;

  /// Posts this account wrote.
  final int posts;

  /// Conversations kept apart from friends and groups (with people who are
  /// not friends yet).
  final int chats;

  /// Invitations sent or received and not answered.
  final int invitations;
  final int friends;
  final int groups;
  final bool pyramid;
  final bool dating;
  final int pebbles;

  /// The account password is set: whoever replaces the account loses the
  /// key it protects.
  final bool accountPassword;

  /// Nothing here the person made or received: another account may take
  /// this device's place without a question.
  bool get isFresh =>
      name.trim().isEmpty &&
      notes == 0 &&
      passwords == 0 &&
      posts == 0 &&
      chats == 0 &&
      invitations == 0 &&
      friends == 0 &&
      groups == 0 &&
      !pyramid &&
      !dating &&
      pebbles == 0 &&
      !accountPassword;

  /// What is here, one line each, as the person reads it.
  List<String> describe() => <String>[
    if (name.trim().isNotEmpty) t('Imię: {name}', {'name': name.trim()}),
    if (friends > 0)
      tn(
        friends,
        one: '{n} znajomy',
        few: '{n} znajomych',
        many: '{n} znajomych',
      ),
    if (invitations > 0)
      tn(
        invitations,
        one: '{n} zaproszenie bez odpowiedzi',
        few: '{n} zaproszenia bez odpowiedzi',
        many: '{n} zaproszeń bez odpowiedzi',
      ),
    if (groups > 0)
      tn(groups, one: '{n} grupa', few: '{n} grupy', many: '{n} grup'),
    if (chats > 0) t('Rozmowy z osobami spoza znajomych'),
    if (notes > 0)
      tn(notes, one: '{n} notatka', few: '{n} notatki', many: '{n} notatek'),
    if (passwords > 0)
      tn(
        passwords,
        one: '{n} zapisane hasło',
        few: '{n} zapisane hasła',
        many: '{n} zapisanych haseł',
      ),
    if (posts > 0)
      tn(posts, one: '{n} wpis', few: '{n} wpisy', many: '{n} wpisów'),
    if (pebbles > 0)
      tn(pebbles, one: '{n} kamyk', few: '{n} kamyki', many: '{n} kamyków'),
    if (dating) t('Profil randkowy'),
    if (pyramid) t('Miejsce w piramidzie i portfel'),
    if (accountPassword) t('Hasło konta i klucz konta, który chroni'),
  ];
}

/// The notes to oneself stored as [raw] (`notes/self`) that are not
/// deleted.
int selfNotesCountOf(Uint8List? raw) {
  if (raw == null) {
    return 0;
  }
  try {
    final Object? json = jsonDecode(utf8.decode(raw));
    if (json is! Map) {
      // Something is there that does not read: not nothing.
      return 1;
    }
    int n = 0;
    for (final Object? v in json.values) {
      if (v is Map && v['d'] != true) {
        n++;
      }
    }
    return n;
  } on FormatException {
    return 1;
  }
}

/// The saved passwords in the vault stored as [raw] (`passwords/vault`).
int passwordsCountOf(Uint8List? raw) {
  if (raw == null) {
    return 0;
  }
  final PasswordVaultDoc? doc = PasswordVaultDoc.fromBytes(raw);
  if (doc == null) {
    // Something is there that does not read: not nothing.
    return 1;
  }
  if (doc.newer) {
    return 1;
  }
  return passwordEntriesOf(doc.versions.values).length;
}

/// The saved passwords the person chose to take along to the account that
/// comes next on this device ("Zabierz zapisane hasła"), held in memory
/// only: until that account is taken (a copy, a backup, a link or a key),
/// at most [keep], and never written anywhere on the way.
final class AccountPasswordCarry {
  AccountPasswordCarry._();

  static final AccountPasswordCarry instance = AccountPasswordCarry._();

  /// How long the passwords wait for the next account.
  static const Duration keep = Duration(hours: 6);

  Map<String, Object?>? _section;
  int _until = 0;

  /// Holds [section] (the vault as a section of a copy) for the next
  /// account; nothing for an empty one.
  void put(Map<String, Object?>? section, {int? now}) {
    if (section == null) {
      return;
    }
    _section = section;
    _until =
        (now ?? DateTime.now().millisecondsSinceEpoch) + keep.inMilliseconds;
  }

  /// Whether passwords wait.
  bool get isHeld => _section != null;

  /// The passwords held, once; null when there are none or they waited too
  /// long.
  Map<String, Object?>? take({int? now}) {
    final Map<String, Object?>? section = _section;
    _section = null;
    if (section == null ||
        (now ?? DateTime.now().millisecondsSinceEpoch) > _until) {
      return null;
    }
    return section;
  }

  /// Drops what is held.
  void clear() => _section = null;
}
