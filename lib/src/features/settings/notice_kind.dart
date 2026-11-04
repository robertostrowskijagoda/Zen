import 'package:zen/src/app/i18n/zen_i18n.dart';

/// The kinds of news the person can switch off one by one (Ustawienia →
/// Powiadomienia i dźwięki). A kind that is off posts no system
/// notification and makes no notification sound; what it tells of is still
/// in the in-app list of notifications, so nothing is lost.
///
/// Each kind has its own level of what a notification says
/// ([AppSettings.privacyFor]); one not set follows the general level.
///
/// Never switched off and not on this list: a friend's alarm, a request
/// for help with an account's recovery, the safety check-ins of a date.
/// [update] is listed but cannot be switched off.
enum NoticeKind {
  /// A message from one person.
  message,

  /// A message in a group chat.
  groupMessage,

  /// A message from someone who is not a friend.
  strangerMessage,

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

  /// A friend opened a gate for someone (an introduction).
  introduction,

  /// Events, plans, dinner circles, a table, meeting intents nearby.
  meetup,

  /// The neighbours: the flat's chat, knocks, members joining and leaving.
  neighbours,

  /// Dating: matches, messages, vouches (not the safety check-ins).
  dating,

  /// "Zapytaj sieć": a question to answer, an answer to a question.
  question,

  /// Pebbles: a friend asks to keep one.
  pebble,

  /// The pyramid: proposals, reports, payments.
  pyramid,

  /// A new version of Zen: always told.
  update;

  /// Whether the switch can turn it off ([update] cannot).
  bool get canMute => this != NoticeKind.update;

  /// Whether a notification of this kind has something to hide, so it has
  /// a level of its own: a ringing call always says who calls, a new
  /// version names nobody.
  bool get hasPrivacy => this != NoticeKind.call && this != NoticeKind.update;

  /// What the switch is called.
  String get label => switch (this) {
    NoticeKind.message => t('Wiadomości'),
    NoticeKind.groupMessage => t('Wiadomości grupowe'),
    NoticeKind.strangerMessage => t('Wiadomości spoza znajomych'),
    NoticeKind.call => t('Połączenia'),
    NoticeKind.mention => t('Wzmianki'),
    NoticeKind.reaction => t('Reakcje na Twoje posty'),
    NoticeKind.friendPost => t('Posty znajomych'),
    NoticeKind.farPost => t('Posty dalszych znajomych'),
    NoticeKind.invitation => t('Zaproszenia i prośby o kontakt'),
    NoticeKind.introduction => t('Przedstawienia'),
    NoticeKind.meetup => t('Spotkania i wydarzenia'),
    NoticeKind.neighbours => t('Sąsiedzi'),
    NoticeKind.dating => t('Randki'),
    NoticeKind.question => t('Pytania do sieci'),
    NoticeKind.pebble => t('Kamyczki'),
    NoticeKind.pyramid => t('Piramida'),
    NoticeKind.update => t('Aktualizacje Zen'),
  };

  /// One line under the switch.
  String get description => switch (this) {
    NoticeKind.message => t('Rozmowy z pojedynczymi osobami.'),
    NoticeKind.groupMessage => t('Rozmowy w grupach.'),
    NoticeKind.strangerMessage => t(
      'Ktoś spoza znajomych pisze do Ciebie (prośba o rozmowę).',
    ),
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
      'Znajomi znajomych, w zasięgu ustawionym na Tablicy. Ich posty '
      'trafiają też na listę w aplikacji; wyłączone, nie trafiają.',
    ),
    NoticeKind.invitation => t(
      'Prośby o kontakt, odpowiedzi na nie i zaproszenia do grup.',
    ),
    NoticeKind.introduction => t(
      'Znajomy otworzył komuś do Ciebie furtkę albo Ciebie komuś przedstawił.',
    ),
    NoticeKind.meetup => t(
      'Wydarzenia, plany, kółka obiadowe, stolik i chęć spotkania w okolicy.',
    ),
    NoticeKind.neighbours => t(
      'Czat mieszkania, pukanie do drzwi, nowi i odchodzący sąsiedzi.',
    ),
    NoticeKind.dating => t(
      'Dopasowania, wiadomości i poręczenia. Pytania o bezpieczeństwo '
      'na randce przychodzą zawsze.',
    ),
    NoticeKind.question => t(
      'Pytania od znajomych do sieci i odpowiedzi na Twoje pytania.',
    ),
    NoticeKind.pebble => t('Prośby znajomych o przechowanie kamyczka.'),
    NoticeKind.pyramid => t('Propozycje, zgłoszenia i płatności w piramidzie.'),
    NoticeKind.update => t(
      'Nowa wersja Zen do pobrania. Zawsze włączone: nowa wersja '
      'przynosi poprawki bezpieczeństwa.',
    ),
  };

  /// The kinds that are off until the person switches them on.
  ///
  /// None: every kind is on until the person switches it off.
  static const Set<NoticeKind> defaultMuted = <NoticeKind>{};

  /// The kind of a notification posted without one, by its id (see the
  /// features' `notify` calls); `null` for what is always told (alarms,
  /// help with a recovery, a date's safety check-ins) or not known.
  static NoticeKind? ofNotificationId(String id) {
    for (final (String prefix, NoticeKind? kind) in _idPrefixes) {
      if (id.startsWith(prefix)) {
        return kind;
      }
    }
    return null;
  }

  /// Longer prefixes first where one starts another.
  static const List<(String, NoticeKind?)> _idPrefixes =
      <(String, NoticeKind?)>[
        ('date-safe-', null),
        ('date-', NoticeKind.dating),
        ('event-', NoticeKind.meetup),
        ('plan-', NoticeKind.meetup),
        ('circle-', NoticeKind.meetup),
        ('intent-', NoticeKind.meetup),
        ('flat-', NoticeKind.neighbours),
        ('ask-', NoticeKind.question),
        ('intro-', NoticeKind.introduction),
        ('pebble-', NoticeKind.pebble),
        ('pyr-', NoticeKind.pyramid),
      ];

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
