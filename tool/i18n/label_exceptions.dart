// Texts that quote a label of the app between „ and ” and, in some
// languages, rightly do not say the label's own translation. Used by the
// check in scanner.dart that a translated text names a control the way the
// app shows it.

/// A quoted label that a text may name differently in some languages.
final class I18nLabelException {
  const I18nLabelException({
    required this.text,
    required this.label,
    required this.languages,
    required this.reason,
  });

  /// The beginning of the Polish text.
  final String text;

  /// The Polish text of the label.
  final String label;

  /// The languages in which the difference is right.
  final Set<String> languages;

  /// Why it is right.
  final String reason;
}

/// Names between „ and ” that are not translated in any language, because
/// the thing they name has one name only. The Shortcuts action of an iPhone
/// is listed under its Polish name in every language until the app has string
/// files for it, so a translated text that sends the person to it must give
/// that name as it is.
const Set<String> kI18nFixedNames = <String>{'Sprawdź wiadomości Zen'};

const List<I18nLabelException> kI18nLabelExceptions = <I18nLabelException>[
  I18nLabelException(
    text: 'Stuknij „Zainstaluj”.',
    label: 'Zainstaluj',
    languages: <String>{'ar', 'id', 'tr'},
    reason: 'the install button of Android itself, which has its own name',
  ),
  I18nLabelException(
    text: 'Znajomi znajomych pojawiają się sami',
    label: 'Randki',
    languages: <String>{'cs'},
    reason: 'the screen\'s name in the accusative case',
  ),
  I18nLabelException(
    text: 'Poszukaj w ustawieniach telefonu (Bateria',
    label: 'Oszczędzanie baterii',
    languages: <String>{'de', 'ja'},
    reason: 'the name of a setting of the phone, which differs by maker',
  ),
  I18nLabelException(
    text: 'Ustawienia → Aplikacje → Zen → włącz „Autostart”.',
    label: 'Oszczędzanie baterii',
    languages: <String>{'de', 'ja'},
    reason: 'the name of a setting of the phone, which differs by maker',
  ),
  I18nLabelException(
    text: 'Ciche dźwięki w aplikacji',
    label: 'Nie przeszkadzać',
    languages: <String>{'de'},
    reason: 'the phone\'s own do-not-disturb mode, not a label of the app',
  ),
  I18nLabelException(
    text: 'Alarm przebija tryb „nie przeszkadzać”',
    label: 'nie przeszkadzać',
    languages: <String>{'ja', 'ro', 'zh'},
    reason: 'the phone\'s own do-not-disturb mode, not a label of the app',
  ),
  I18nLabelException(
    text: 'Ustaw status „na teraz”',
    label: 'Na teraz',
    languages: <String>{'hi', 'ja', 'uk'},
    reason: 'a status written in lower case, not the heading of the screen',
  ),
  I18nLabelException(
    text: 'Zen to komunikator i sieć',
    label: 'Na teraz',
    languages: <String>{'hi', 'uk'},
    reason: 'a status written in lower case, not the heading of the screen',
  ),
  I18nLabelException(
    text: 'Znajomi oznaczeni jako „znajomi”',
    label: 'znajomi',
    languages: <String>{'hu', 'tr'},
    reason: 'the level "Friend" in a sentence, not the legend of the graph',
  ),
  I18nLabelException(
    text: 'Żeby alarm z zablokowanego ekranu',
    label: 'zawsze',
    languages: <String>{'ro'},
    reason: 'the answer of the phone\'s own permission window',
  ),
  I18nLabelException(
    text: 'Zgódź się albo odmów w „Domownicy”',
    label: 'Domownicy',
    languages: <String>{'ru', 'uk'},
    reason: 'the screen\'s name in the prepositional case',
  ),
  I18nLabelException(
    text: 'Usuń z niego konto',
    label: 'Urządzenia',
    languages: <String>{'uk'},
    reason: 'the screen\'s name in the prepositional case',
  ),
];
