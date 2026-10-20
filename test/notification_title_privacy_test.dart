import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

/// S-12: with "Powiadomienia bez treści" on, the features whose title
/// alone tells too much get a generic title as well.
void main() {
  RuntimeSystemNotification post(
    String id,
    String title, {
    RuntimeSystemNotificationCategory category =
        RuntimeSystemNotificationCategory.social,
    bool redacted = false,
  }) => RuntimeSystemNotification(
    id: id,
    title: title,
    body: 'Tajna treść',
    createdAtMillis: 1,
    category: category,
    slotKey: id,
    contentRedacted: redacted,
  );

  Future<Map<String, RuntimeSystemNotification>> shown(
    List<RuntimeSystemNotification> posts, {
    bool hide = true,
  }) async {
    final MemoryRuntimeSystemNotificationService shade =
        MemoryRuntimeSystemNotificationService();
    final PrivacyRedactingNotificationService service =
        PrivacyRedactingNotificationService(shade, hideContent: () => hide);
    for (final RuntimeSystemNotification notification in posts) {
      await service.show(notification);
    }
    return <String, RuntimeSystemNotification>{
      for (final RuntimeSystemNotification n in shade.activeNotifications)
        n.id: n,
    };
  }

  test('dating, questions, events, introductions and the pyramid get a '
      'generic title', () async {
    final Map<String, RuntimeSystemNotification> byId =
        await shown(<RuntimeSystemNotification>[
          post('date-safe-7', 'Kasia idzie na randkę'),
          post('ask-answer-3-1', 'Odpowiedź: czy on jest w porządku?'),
          post('event-12', 'Zaproszenie: Urodziny Ani'),
          post('plan-4', 'Kto chętny? Kino'),
          post('circle-9', 'Nowe kółko obiadowe: Sąsiedzi'),
          post('intro-5', 'Ola chce Cię komuś przedstawić'),
          post('pyr-prop-2', 'Piramida: do podpisania'),
          post(
            'date-msg-8',
            'Tomek',
            category: RuntimeSystemNotificationCategory.message,
          ),
          post('date-ask-6', 'Kasia pyta o opinię', redacted: true),
        ]);
    for (final RuntimeSystemNotification n in byId.values) {
      expect(
        n.title,
        PrivacyRedactingNotificationService.genericTitle,
        reason: n.id,
      );
      expect(n.body, isNot(contains('Tajna')), reason: n.id);
    }
    expect(byId['date-msg-8']!.body, 'Nowa wiadomość');
  });

  test('alarms, calls, a safe-date check-in and other notifications keep '
      'their title', () async {
    final Map<String, RuntimeSystemNotification> byId =
        await shown(<RuntimeSystemNotification>[
          post(
            'date-safe-alarm-1',
            '⚠️ Kasia nie potwierdziła, że wszystko OK',
            category: RuntimeSystemNotificationCategory.alarm,
          ),
          post(
            'pyr-crisis-1',
            'Kryzys',
            category: RuntimeSystemNotificationCategory.alarm,
          ),
          post(
            'call-invite-1',
            'Połączenie od Kasi',
            category: RuntimeSystemNotificationCategory.call,
          ),
          post('date-safe-rem-1', 'Wszystko OK?'),
          post('alarm-resp-1-x', 'Kasia: Jadę'),
          post('friend-request-1', 'Kasia'),
        ]);
    expect(byId['date-safe-alarm-1']!.body, 'Tajna treść');
    expect(byId['pyr-crisis-1']!.title, 'Kryzys');
    expect(byId['call-invite-1']!.title, 'Połączenie od Kasi');
    expect(byId['date-safe-rem-1']!.title, 'Wszystko OK?');
    expect(byId['alarm-resp-1-x']!.title, 'Kasia: Jadę');
    expect(byId['friend-request-1']!.title, 'Kasia');
    // Their bodies still go (they are not alarms or calls).
    expect(byId['friend-request-1']!.body, isNot(contains('Tajna')));
  });

  test('with the setting off nothing changes', () async {
    final Map<String, RuntimeSystemNotification> byId = await shown(
      <RuntimeSystemNotification>[post('date-safe-7', 'Kasia idzie na randkę')],
      hide: false,
    );
    expect(byId['date-safe-7']!.title, 'Kasia idzie na randkę');
    expect(byId['date-safe-7']!.body, 'Tajna treść');
  });
}
