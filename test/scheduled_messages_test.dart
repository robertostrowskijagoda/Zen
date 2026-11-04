import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/chat/scheduled_messages.dart';

// "Wyślij później": what waits goes at its time, once, and a failed send
// is tried again.
void main() {
  const String ola = '200:1111:2222:3333:4444:5555:6666:7777';

  test('a message goes at its time, once; the others wait', () async {
    int now = 1000;
    final List<String> sent = <String>[];
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final ScheduledMessagesService scheduled = ScheduledMessagesService(
      disk: disk,
      send: (String to, String text) async => sent.add('$to $text'),
      now: () => now,
    );
    await scheduled.schedule(to: ola, text: 'Rano', atMillis: 5000);
    await scheduled.schedule(to: ola, text: 'Wieczorem', atMillis: 9000);
    await scheduled.schedule(to: ola, text: '   ', atMillis: 5000);
    await scheduled.sendDue();
    expect(sent, isEmpty);

    now = 6000;
    await scheduled.sendDue();
    await scheduled.sendDue();
    expect(sent, <String>['$ola Rano']);
    expect(scheduled.waiting(ola).single.text, 'Wieczorem');

    // Kept across a restart.
    final ScheduledMessagesService again = ScheduledMessagesService(
      disk: disk,
      send: (String to, String text) async => sent.add('$to $text'),
      now: () => 10000,
    );
    await again.sendDue();
    expect(sent.last, '$ola Wieczorem');
    expect(again.waiting(), isEmpty);
  });

  test('a cancelled one never goes; a failed send stays for the next '
      'run', () async {
    bool fail = true;
    final List<String> sent = <String>[];
    final ScheduledMessagesService scheduled = ScheduledMessagesService(
      disk: MemoryLedgerDisk(),
      send: (String to, String text) async {
        if (fail) {
          throw StateError('offline');
        }
        sent.add(text);
      },
      now: () => 10000,
    );
    final ScheduledMessage gone = (await scheduled.schedule(
      to: ola,
      text: 'Nie',
      atMillis: 1,
    ))!;
    await scheduled.schedule(to: ola, text: 'Tak', atMillis: 1);
    await scheduled.cancel(gone.id);
    await scheduled.sendDue();
    expect(sent, isEmpty);
    expect(scheduled.waiting(), hasLength(1));
    fail = false;
    await scheduled.sendDue();
    expect(sent, <String>['Tak']);
  });
}
