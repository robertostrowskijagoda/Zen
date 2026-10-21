import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/meet/meet_book.dart';

/// How many phone numbers the backup SMS of the alarm keeps.
const int kAlarmSmsMaxNumbers = 5;

/// A phone number as the SMS app takes it: an optional leading "+" and
/// 5–15 digits, spaces, dashes and brackets dropped. `null` for anything
/// else.
String? normalizeSmsNumber(String raw) {
  final String t = raw.trim();
  final bool plus = t.startsWith('+');
  final String digits = t
      .replaceAll(RegExp(r'[\s\-().]'), '')
      .replaceFirst(RegExp(r'^\+'), '');
  if (!RegExp(r'^\d{5,15}$').hasMatch(digits)) {
    return null;
  }
  return plus ? '+$digits' : digits;
}

/// Reads numbers typed separated by commas, semicolons or new lines
/// (spaces may sit inside a number): the valid ones, without repeats, at
/// most [kAlarmSmsMaxNumbers].
List<String> parseSmsNumbers(String text) {
  final List<String> out = <String>[];
  for (final String part in text.split(RegExp(r'[,;\n]'))) {
    final String? n = normalizeSmsNumber(part);
    if (n != null && !out.contains(n)) {
      out.add(n);
    }
    if (out.length >= kAlarmSmsMaxNumbers) {
      break;
    }
  }
  return out;
}

/// The text of the backup SMS: who needs help, the note, where (a link
/// anyone can open) and that 112 is the call to make.
String alarmSmsBody({required String name, required AlarmRecord alarm}) {
  final String who = name.trim().isEmpty ? t('Ktoś') : name.trim();
  final double? lat = alarm.lat;
  final double? lon = alarm.lon;
  return <String>[
    t('ALARM (Zen): {name} potrzebuje pomocy.', {'name': who}),
    if (alarm.note.trim().isNotEmpty) '„${alarm.note.trim()}”',
    if (lat != null && lon != null)
      t('Położenie: {link}', {'link': mapUrl(lat, lon)})
    else
      t('Położenia brak.'),
    t('Zadzwoń do tej osoby albo na 112.'),
  ].join(' ');
}

/// Opens the SMS app with the alarm text for [numbers] (the person presses
/// send). `false` when nothing could be opened.
Future<bool> sendAlarmSms({
  required List<String> numbers,
  required String name,
  required AlarmRecord alarm,
}) => openSmsComposer(numbers, alarmSmsBody(name: name, alarm: alarm));
