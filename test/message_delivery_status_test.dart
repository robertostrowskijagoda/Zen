import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/features/chat/presentation/message_delivery_badge.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_providers.dart';

const int _now = 10 * 60 * 1000;

ChatMessage _out(
  ChatMessageDeliveryState state, {
  int sentAt = _now - 1000,
  int? readAt,
  ChatMessageType type = ChatMessageType.text,
}) => ChatMessage(
  id: 'm1',
  sender: 'self',
  text: 'Hej',
  sentAtMillis: sentAt,
  direction: ChatMessageDirection.outgoing,
  deliveryState: state,
  readAtMillis: readAt,
  type: type,
);

MessageDeliveryStage? _stage(
  ChatMessage message, {
  MessageDeliveryProgress? progress,
  bool queueKnown = true,
  bool isGroup = false,
}) => MessageDeliveryStatus.of(
  message,
  progress: progress,
  queueKnown: queueKnown,
  isGroup: isGroup,
  nowMillis: _now,
)?.stage;

void main() {
  group('status of an outgoing message', () {
    test('follows the queue: sending, waiting here, with the mailboxes, '
        'delivered, read', () {
      final ChatMessage sent = _out(ChatMessageDeliveryState.sent);
      expect(
        _stage(
          sent,
          progress: const MessageDeliveryProgress(recipients: 1, sending: 1),
        ),
        MessageDeliveryStage.sending,
      );
      expect(
        _stage(
          sent,
          progress: const MessageDeliveryProgress(
            recipients: 1,
            waitingHere: 1,
          ),
        ),
        MessageDeliveryStage.waitingHere,
      );
      final MessageDeliveryStatus held = MessageDeliveryStatus.of(
        sent,
        progress: const MessageDeliveryProgress(
          recipients: 1,
          inMailboxes: 1,
          mailboxCopies: 3,
        ),
        queueKnown: true,
        nowMillis: _now,
      )!;
      expect(held.stage, MessageDeliveryStage.inMailboxes);
      expect(held.mailboxCopies, 3);
      expect(
        messageDeliveryLabel(held),
        'Czeka na odbiór u zaufanych znajomych odbiorcy (3)',
      );
      expect(
        _stage(
          sent,
          progress: const MessageDeliveryProgress(recipients: 1, delivered: 1),
        ),
        MessageDeliveryStage.delivered,
      );
      expect(
        _stage(_out(ChatMessageDeliveryState.delivered)),
        MessageDeliveryStage.delivered,
      );
      expect(
        _stage(_out(ChatMessageDeliveryState.delivered, readAt: _now)),
        MessageDeliveryStage.read,
      );
      expect(
        _stage(_out(ChatMessageDeliveryState.failed)),
        MessageDeliveryStage.failed,
      );
    });

    test('a text the queue never got is failed after a while, and only '
        'when the queue is known', () {
      final ChatMessage lost = _out(
        ChatMessageDeliveryState.sending,
        sentAt: _now - const Duration(minutes: 5).inMilliseconds,
      );
      expect(_stage(lost), MessageDeliveryStage.failed);
      expect(
        MessageDeliveryStatus.of(
          lost,
          queueKnown: true,
          nowMillis: _now,
        )!.canRetry,
        isTrue,
      );
      expect(_stage(lost, queueKnown: false), MessageDeliveryStage.sending);
      expect(
        _stage(_out(ChatMessageDeliveryState.sending)),
        MessageDeliveryStage.sending,
        reason: 'just written',
      );
      expect(
        _stage(
          _out(
            ChatMessageDeliveryState.sending,
            sentAt: 0,
            type: ChatMessageType.image,
          ),
        ),
        MessageDeliveryStage.sending,
        reason: 'attachments have their own transfer',
      );
    });

    test('a group adds up its members, shows no read receipts and fails '
        'only when someone never got it', () {
      final ChatMessage sent = _out(ChatMessageDeliveryState.sent);
      final MessageDeliveryStatus partial = MessageDeliveryStatus.of(
        sent,
        progress: const MessageDeliveryProgress(
          recipients: 3,
          delivered: 2,
          inMailboxes: 1,
          mailboxCopies: 4,
        ),
        queueKnown: true,
        isGroup: true,
        nowMillis: _now,
      )!;
      expect(partial.stage, MessageDeliveryStage.inMailboxes);
      expect(partial.isPartial, isTrue);
      expect(messageDeliveryLabel(partial), 'Dostarczono 2 z 3');
      expect(
        _stage(
          sent,
          isGroup: true,
          progress: const MessageDeliveryProgress(
            recipients: 3,
            delivered: 1,
            waitingHere: 1,
            inMailboxes: 1,
          ),
        ),
        MessageDeliveryStage.waitingHere,
        reason: 'whoever is furthest behind',
      );
      final MessageDeliveryStatus failed = MessageDeliveryStatus.of(
        sent,
        progress: const MessageDeliveryProgress(
          recipients: 3,
          delivered: 2,
          failed: 1,
        ),
        queueKnown: true,
        isGroup: true,
        nowMillis: _now,
      )!;
      expect(failed.stage, MessageDeliveryStage.failed);
      expect(messageDeliveryLabel(failed), 'Nie dotarło do 1 osoby — ponów');
      expect(
        _stage(
          _out(ChatMessageDeliveryState.delivered, readAt: _now),
          isGroup: true,
        ),
        MessageDeliveryStage.delivered,
      );
    });

    test('what is too large for the mailboxes waits for both to be online', () {
      expect(
        _stage(
          _out(ChatMessageDeliveryState.sent),
          progress: const MessageDeliveryProgress(
            recipients: 1,
            waitingForBoth: 1,
          ),
        ),
        MessageDeliveryStage.waitingForBoth,
      );
      expect(
        _stage(
          _out(ChatMessageDeliveryState.none, type: ChatMessageType.video),
        ),
        MessageDeliveryStage.waitingForBoth,
        reason: 'a big attachment waiting for a transfer',
      );
      expect(
        _stage(
          _out(ChatMessageDeliveryState.sent),
          isGroup: true,
          progress: const MessageDeliveryProgress(
            recipients: 2,
            delivered: 1,
            waitingForBoth: 1,
          ),
        ),
        MessageDeliveryStage.waitingForBoth,
      );
    });

    test('nothing for messages that are not outgoing', () {
      const ChatMessage incoming = ChatMessage(
        id: 'in',
        sender: 'peer',
        text: 'Cześć',
        sentAtMillis: 1,
        direction: ChatMessageDirection.incoming,
      );
      expect(
        MessageDeliveryStatus.of(incoming, queueKnown: true, nowMillis: _now),
        isNull,
      );
    });
  });

  testWidgets('the legend names every delivery status', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(child: MessageDeliveryLegend()),
        ),
      ),
    );
    for (final String label in <String>[
      'Wysyłanie…',
      'Czeka u Ciebie — odbiorca offline',
      'Czeka u Ciebie — dojdzie, gdy oboje będziecie online',
      'Czeka na odbiór u zaufanych znajomych odbiorcy (N)',
      'Wysłano',
      'Dostarczono',
      'Przeczytano',
      'Nie udało się — ponów',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    for (final MessageDeliveryStage stage in MessageDeliveryStage.values) {
      expect(
        find.byKey(Key('message-delivery-legend-${stage.name}')),
        findsOneWidget,
        reason: stage.name,
      );
    }
  });

  testWidgets('tapping the status shows its label, what it means and the '
      'legend', (WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          relayDeliveryProgressProvider.overrideWithValue(
            const RelayProgressSnapshot(
              ready: true,
              messages: <String, MessageDeliveryProgress>{
                'm1': MessageDeliveryProgress(
                  recipients: 1,
                  inMailboxes: 1,
                  mailboxCopies: 2,
                  heldBySelf: true,
                ),
              },
            ),
          ),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: Scaffold(
            body: Center(
              child: MessageDeliveryBadge(
                message: _out(
                  ChatMessageDeliveryState.sent,
                  sentAt: DateTime.now().millisecondsSinceEpoch,
                ),
                conversationKey: 'peer',
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.markunread_mailbox_outlined), findsOneWidget);

    await tester.tap(find.byKey(const Key('message-delivery-m1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-delivery-details')), findsOneWidget);
    expect(
      find.text('Czeka na odbiór u zaufanych znajomych odbiorcy (2)'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Jedną z kopii trzymasz Ty — jesteś zaufanym znajomym odbiorcy.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('message-delivery-legend')), findsOneWidget);
    expect(find.byKey(const Key('message-delivery-retry')), findsNothing);
  });

  testWidgets('a failed message offers "Ponów"', (WidgetTester tester) async {
    int retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showMessageDeliveryDetails(
                  context,
                  status: const MessageDeliveryStatus(
                    MessageDeliveryStage.failed,
                  ),
                  onRetry: () async => retries++,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Nie udało się — ponów'), findsWidgets);

    final Finder retry = find.byKey(const Key('message-delivery-retry'));
    await tester.ensureVisible(retry);
    await tester.pump();
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(retries, 1);
    expect(find.byKey(const Key('message-delivery-details')), findsNothing);
  });
}
