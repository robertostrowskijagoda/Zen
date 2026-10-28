import 'package:zen/src/app/i18n/zen_i18n.dart';

/// The kinds of news the person can switch off one by one (Ustawienia →
/// Powiadomienia i dźwięki). A kind that is off posts no system
/// notification and makes no notification sound; what it tells of is still
/// in the in-app list of notifications, so nothing is lost.
///
/// Alarms, the neighbours, dating, the meet-ups and the other duties of
/// the app are not here: they are never switched off from this list.
enum NoticeKind {
  /// A message from one person.
  message,

  /// A message in a group chat.
  groupMessage,

  /// An incoming call (ringing, missed, group calls).
  call,

  /// Someone mentioned this person in a post, a comment or a group chat.
  mention,

  /// Likes and comments under this person's own posts.
  reaction,

  /// A new post of a direct friend.
  friendPost,

  /// A new post of a friend of a friend (the 2nd and 3rd degree, as far as
  /// the Tablica looks).
  farPost,

  /// A friend request, its answer, an invitation to a group.
  invitation,

  /// A new version of Zen.
  update;

  /// What the switch is called.
  String get label => switch (this) {
    NoticeKind.message => t('Wiadomości'),
    NoticeKind.groupMessage => t('Wiadomości grupowe'),
    NoticeKind.call => t('Połączenia'),
    NoticeKind.mention => t('Wzmianki'),
    NoticeKind.reaction => t('Reakcje na Twoje posty'),
    NoticeKind.friendPost => t('Posty znajomych'),
    NoticeKind.farPost => t('Posty dalszych znajomych'),
    NoticeKind.invitation => t('Zaproszenia i prośby o kontakt'),
    NoticeKind.update => t('Aktualizacje Zen'),
  };

  /// One line under the switch.
  String get description => switch (this) {
    NoticeKind.message => t('Rozmowy z pojedynczymi osobami.'),
    NoticeKind.groupMessage => t('Rozmowy w grupach.'),
    NoticeKind.call => t(
      'Wyłączone: telefon nie dzwoni i nie pokazuje karty połączenia, gdy '
      'Zen jest w tle. Nieodebrane połączenia zostają na liście w '
      'aplikacji.',
    ),
    NoticeKind.mention => t(
      'Ktoś oznaczył Cię w poście, komentarzu albo wiadomości grupowej.',
    ),
    NoticeKind.reaction => t('Polubienia i komentarze pod Twoimi postami.'),
    NoticeKind.friendPost => t(
      'Nowy post kogoś z Twoich znajomych. Wyłączone: nie ma też wpisu na '
      'liście w aplikacji. Jedną osobę wyciszysz w menu jej posta albo '
      'rozmowy.',
    ),
    NoticeKind.farPost => t(
      'Znajomi znajomych, w zasięgu ustawionym na Tablicy. Domyślnie '
      'wyłączone; włączone, ich posty trafiają też na listę w aplikacji.',
    ),
    NoticeKind.invitation => t(
      'Prośby o kontakt, odpowiedzi na nie i zaproszenia do grup.',
    ),
    NoticeKind.update => t('Nowa wersja Zen do pobrania.'),
  };

  /// The kinds that are off until the person switches them on.
  static const Set<NoticeKind> defaultMuted = <NoticeKind>{NoticeKind.farPost};

  /// The kind stored under [name], or `null`.
  static NoticeKind? byName(Object? name) {
    for (final NoticeKind kind in values) {
      if (kind.name == name) {
        return kind;
      }
    }
    return null;
  }
}
