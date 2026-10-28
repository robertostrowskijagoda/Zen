import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/messages/chat_message.dart';

/// `ChatMessage.mimeType` of a system message whose `fileName` holds its
/// [SocialEventText] (see [chatMessageWithEvent]).
///
/// The stored formats stay as they are: a system message never has a file,
/// so these two fields are free; older builds ignore them and show the
/// saved text.
const String kSocialEventMimeType = 'application/vnd.zen.event+json';

/// A text the app saves (a system message in a chat, an inbox entry) kept
/// as an event [code] and its [args], and put into words in the app's
/// language when it is shown: switching the language also
/// changes what was saved before. The text made when it was saved stays
/// next to it, for older builds and codes this build does not know.
///
/// Arguments are what the event was about, not words: `name` (empty for
/// "Ktoś"), `group` (empty for the default name), `kind` (a
/// `CallInviteKind` name), or values from outside (`error`, `members`).
@immutable
final class SocialEventText {
  const SocialEventText(this.code, [this.args = const <String, String>{}]);

  /// The longest code and argument kept from a stored event.
  static const int _maxCode = 64;
  static const int _maxArgs = 8;
  static const int _maxArg = 2000;

  final String code;
  final Map<String, String> args;

  /// The text in the app's current language; null for a code this build
  /// does not know (the saved text is shown instead).
  String? renderOrNull() {
    final Map<String, String> a = args;
    final String name = _name(a);
    final String kind = _kind(a);
    final String group = a['group']?.trim() ?? '';
    return switch (code) {
      // A conversation with one friend.
      'chat.attachmentFailed' => t(
        'Nie udało się odebrać załącznika od {name}: {error}',
        {'name': name, 'error': a['error'] ?? ''},
      ),
      // Saved before the friend's name was known: no placeholder in its
      // place (see [chatMessageText] for the name put in later).
      'chat.connected' =>
        (a['name']?.trim() ?? '').isEmpty
            ? t('Połączenie gotowe. Możesz pisać od razu.')
            : t('Połączenie z {name} jest gotowe.', {'name': name}),
      'chat.inviteRejected' => t('{name} odrzucił(a) zaproszenie.', {
        'name': name,
      }),
      'chat.inviteCancelled' => t(
        '{name} anulował(a) oczekujące zaproszenie.',
        {'name': name},
      ),
      'chat.transferCancelled' => t(
        'Transfer został anulowany i stan obu stron jest zgodny.',
      ),
      'call.inviteIn' => t('Przyszło zaproszenie do rozmowy {kind}.', {
        'kind': kind,
      }),
      'call.inviteOut' => t('Wysłano zaproszenie do rozmowy {kind}.', {
        'kind': kind,
      }),
      'call.answeredBy' => t('{name} odebrał(a) rozmowę {kind}.', {
        'name': name,
        'kind': kind,
      }),
      'call.busy' => t(
        '{name} jest aktualnie zajęty(a) i nie może odebrać rozmowy '
        '{kind}.',
        {'name': name, 'kind': kind},
      ),
      'call.declinedBy' => t('{name} odrzucił(a) rozmowę {kind}.', {
        'name': name,
        'kind': kind,
      }),
      'call.endedBy' => t('{name} zakończył(a) rozmowę {kind}.', {
        'name': name,
        'kind': kind,
      }),
      'call.missed' => t('Nieodebrane połączenie {kind}.', {'kind': kind}),
      'call.noAnswer' => t('Brak odpowiedzi na połączenie {kind}.', {
        'kind': kind,
      }),
      'call.failed' => t(
        'Nie udało się zestawić rozmowy {kind} — druga strona nie '
        'odpowiada.',
        {'kind': kind},
      ),
      'call.declined' => t('Odrzucono rozmowę {kind}.', {'kind': kind}),
      'call.ended' => t('Zakończono rozmowę {kind}.', {'kind': kind}),
      'call.answered' => t('Odebrano rozmowę {kind}.', {'kind': kind}),
      // A group conversation.
      'group.left' => t('{name} opuścił(a) grupę.', {'name': name}),
      'group.added' => t('{name} dodał(a) do grupy: {members}.', {
        'name': name,
        'members': a['members'] ?? '',
      }),
      'groupCall.missed' => t('Nieodebrane połączenie grupowe ({kind}).', {
        'kind': kind,
      }),
      'groupCall.declined' => t('Odrzucono połączenie grupowe ({kind}).', {
        'kind': kind,
      }),
      'groupCall.started' => t('Rozpoczęto połączenie grupowe ({kind}).', {
        'kind': kind,
      }),
      'groupCall.joined' => t('Dołączono do połączenia grupowego.'),
      'groupCall.left' => t('Opuszczono połączenie grupowe.'),
      'groupCall.ended' => t('Zakończono połączenie grupowe.'),
      'groupCall.nobody' => t('Nikt nie dołączył do połączenia grupowego.'),
      // The inbox.
      'inbox.friendRequest' => t('Nowe zaproszenie od {name}', {'name': name}),
      'inbox.friendRequest.body' => t('Chce dodać Cię do znajomych.'),
      'inbox.friendAccepted' => t('{name} zaakceptował(a) zaproszenie', {
        'name': name,
      }),
      'inbox.friendAccepted.body' => t('Możecie już pisać i dzwonić.'),
      'inbox.friendRejected' => t('{name} odrzucił(a) zaproszenie', {
        'name': name,
      }),
      'inbox.friendRejected.body' => t('Zaproszenie nie zostało przyjęte.'),
      'inbox.friendCancelled' => t('{name} wycofał(a) zaproszenie', {
        'name': name,
      }),
      'inbox.friendCancelled.body' => t('Zaproszenie nie jest już aktualne.'),
      'inbox.friendRemoved' => t('{name} usunął(-ęła) Cię ze znajomych', {
        'name': name,
      }),
      'inbox.friendRemoved.body' => t('Nie możecie już do siebie pisać.'),
      'inbox.transferCancelled' => t('Przesyłanie pliku anulowane'),
      'inbox.transferCancelled.body' => t('Nadawca przerwał wysyłanie pliku.'),
      'inbox.message' => t('Nowa wiadomość od {name}', {'name': name}),
      'inbox.message.body' => t('Masz nową wiadomość do przeczytania.'),
      'inbox.callFrom' => t('Połączenie od {name}', {'name': name}),
      'inbox.callFrom.body' => t('Przychodzące połączenie {kind}.', {
        'kind': kind,
      }),
      'inbox.callAnswered' => t('{name} odebrał(a) rozmowę', {'name': name}),
      'inbox.callAnswered.body' => t('Połączenie {kind} jest już aktywne.', {
        'kind': kind,
      }),
      'inbox.callDeclined' => t('{name} odrzucił(a) rozmowę', {'name': name}),
      'inbox.callDeclined.body' => t('Sesja {kind} została zakończona.', {
        'kind': kind,
      }),
      'inbox.callBusy' => t('{name} jest zajęty(a)', {'name': name}),
      'inbox.callBusy.body' => t('Rozmowa {kind} nie mogła się rozpocząć.', {
        'kind': kind,
      }),
      'inbox.callEnded' => t('{name} zakończył(a) rozmowę', {'name': name}),
      'inbox.callEnded.body' => t('Sesja {kind} została zamknięta.', {
        'kind': kind,
      }),
      'inbox.groupInvite' => t('Zaproszenie do grupy: {group}', {
        'group': group.isEmpty ? t('Nowa grupa') : group,
      }),
      'inbox.groupInvite.body' => t('{name} zaprasza Cię do grupy.', {
        'name': name,
      }),
      'inbox.groupMessage' => '${group.isEmpty ? t('Grupa') : group}: $name',
      'inbox.groupMessage.body' => t('Nowa wiadomość w grupie.'),
      'inbox.mention' => t('{name} wspomniał(a) o Tobie', {'name': name}),
      'inbox.groupMention.body' => t('W grupie {group}', {
        'group': group.isEmpty ? t('Grupa') : group,
      }),
      'inbox.groupCall' => t('Połączenie grupowe: {group}', {
        'group': group.isEmpty ? t('Grupa') : group,
      }),
      'inbox.groupCall.body' => t('Trwa połączenie grupowe.'),
      'inbox.event' => t('Nowe zdarzenie'),
      'inbox.event.body' => t('Nowy wpis od {name}.', {'name': name}),
      _ => null,
    };
  }

  /// The text in the app's current language, or [fallback] (the text saved
  /// with it) for a code this build does not know.
  String render([String fallback = '']) => renderOrNull() ?? fallback;

  /// This event about [name] instead of whoever it named when it was saved
  /// (only an event that names someone).
  SocialEventText withName(String name) => args.containsKey('name')
      ? SocialEventText(code, <String, String>{...args, 'name': name})
      : this;

  static String _name(Map<String, String> a) {
    final String name = a['name']?.trim() ?? '';
    return name.isEmpty ? t('Ktoś') : name;
  }

  /// "wideo" or "audio", as the call texts put it.
  static String _kind(Map<String, String> a) =>
      a['kind'] == 'video' ? t('wideo') : t('audio');

  Map<String, Object?> toJson() => <String, Object?>{
    'c': code,
    if (args.isNotEmpty) 'a': args,
  };

  /// The event in [json], or null when it is not one (cut to sane sizes:
  /// it is read back from disk).
  static SocialEventText? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? code = json['c'];
    if (code is! String || code.isEmpty || code.length > _maxCode) {
      return null;
    }
    final Object? rawArgs = json['a'];
    final Map<String, String> args = <String, String>{};
    if (rawArgs is Map) {
      for (final MapEntry<Object?, Object?> e in rawArgs.entries) {
        if (args.length >= _maxArgs) {
          break;
        }
        final Object? key = e.key;
        final Object? value = e.value;
        if (key is String && key.length <= _maxCode && value is String) {
          args[key] = value.length > _maxArg
              ? value.substring(0, _maxArg)
              : value;
        }
      }
    }
    return SocialEventText(code, Map<String, String>.unmodifiable(args));
  }

  String encode() => jsonEncode(toJson());

  static SocialEventText? decode(String? raw) {
    if (raw == null || raw.isEmpty || raw.length > 32 * 1024) {
      return null;
    }
    try {
      return fromJson(jsonDecode(raw));
    } on FormatException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SocialEventText &&
      other.code == code &&
      mapEquals(other.args, args);

  @override
  int get hashCode => Object.hash(
    code,
    Object.hashAllUnordered(
      args.entries.map(
        (MapEntry<String, String> e) => Object.hash(e.key, e.value),
      ),
    ),
  );

  @override
  String toString() => 'SocialEventText($code, $args)';
}

/// [message] (a system message) carrying [event], so it is shown in the
/// language of the moment (see [chatMessageText]).
ChatMessage chatMessageWithEvent(ChatMessage message, SocialEventText event) =>
    message.copyWith(fileName: event.encode(), mimeType: kSocialEventMimeType);

/// The event a system message carries, if any.
SocialEventText? chatMessageEvent(ChatMessage message) =>
    message.isSystem && message.mimeType == kSocialEventMimeType
    ? SocialEventText.decode(message.fileName)
    : null;

/// What [message] says, for the screen: a system message with an event in
/// the app's current language, everything else as it was saved.
///
/// In a chat with one friend every event names that friend: with
/// [peerName] (their name, once it is known) it is said with the name
/// they have now, not the one known when it was saved ("Połączenie z Ada
/// jest gotowe" once Ada's profile came, though her answer came without
/// it).
String chatMessageText(ChatMessage message, {String? peerName}) {
  SocialEventText? event = chatMessageEvent(message);
  if (event == null) {
    return message.text;
  }
  final String name = peerName?.trim() ?? '';
  if (name.isNotEmpty) {
    event = event.withName(name);
  }
  return event.render(message.text);
}
