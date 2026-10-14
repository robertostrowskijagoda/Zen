import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_notification_center.dart';

void main() {
  test('memory notification center stores and clears notifications', () async {
    final MemoryRuntimeNotificationCenter center =
        MemoryRuntimeNotificationCenter();
    int listenerCalls = 0;
    center.addListener(() {
      listenerCalls += 1;
    });

    await center.show(
      const RuntimeNotification(
        id: 'alert-1',
        title: 'Nowa wiadomość',
        body: 'Ada napisala.',
        createdAtMillis: 1,
        routeKey: 'zen://chat/ada.ygg?title=Ada',
        dedupKey: 'message:ada.ygg',
      ),
    );
    await center.show(
      const RuntimeNotification(
        id: 'alert-2',
        title: 'Nowe zaproszenie',
        body: 'Kuba czeka w skrzynce.',
        createdAtMillis: 2,
        routeKey: 'zen://inbox',
      ),
    );
    await center.show(
      const RuntimeNotification(
        id: 'alert-3',
        title: 'Ada napisala jeszcze raz',
        body:
            'Nowsza wiadomość powinna zastapic starszy alert tej samej klasy.',
        createdAtMillis: 3,
        routeKey: 'zen://chat/ada.ygg?title=Ada',
        dedupKey: 'message:ada.ygg',
      ),
    );

    expect(center.activeNotifications, hasLength(2));
    expect(center.activeNotifications.first.id, 'alert-3');
    expect(listenerCalls, 3);
    expect(
      center.activeNotifications.where(
        (entry) => entry.dedupKey == 'message:ada.ygg',
      ),
      hasLength(1),
    );

    await center.dismiss('alert-2');
    expect(center.activeNotifications.single.id, 'alert-3');
    expect(listenerCalls, 4);

    await center.clear();
    expect(center.activeNotifications, isEmpty);
    expect(listenerCalls, 5);
  });
}
