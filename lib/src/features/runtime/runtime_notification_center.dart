import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final runtimeNotificationCenterProvider = Provider<RuntimeNotificationCenter>((
  Ref ref,
) {
  return MemoryRuntimeNotificationCenter();
});

@immutable
final class RuntimeNotification {
  const RuntimeNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAtMillis,
    this.routeKey,
    this.dedupKey,
  });

  final String id;
  final String title;
  final String body;
  final int createdAtMillis;
  final String? routeKey;
  final String? dedupKey;
}

abstract interface class RuntimeNotificationCenter implements Listenable {
  List<RuntimeNotification> get activeNotifications;

  Future<void> show(RuntimeNotification notification);

  Future<void> dismiss(String id);

  Future<void> clear();
}

final class MemoryRuntimeNotificationCenter extends ChangeNotifier
    implements RuntimeNotificationCenter {
  MemoryRuntimeNotificationCenter([
    List<RuntimeNotification> initialNotifications =
        const <RuntimeNotification>[],
  ]) : _activeNotifications = List<RuntimeNotification>.from(
         initialNotifications,
         growable: true,
       );

  final List<RuntimeNotification> _activeNotifications;

  @override
  List<RuntimeNotification> get activeNotifications =>
      List<RuntimeNotification>.unmodifiable(_activeNotifications);

  @override
  Future<void> show(RuntimeNotification notification) async {
    _activeNotifications.removeWhere(
      (RuntimeNotification entry) =>
          entry.id == notification.id ||
          (notification.dedupKey != null &&
              notification.dedupKey == entry.dedupKey),
    );
    _activeNotifications.insert(0, notification);
    notifyListeners();
  }

  @override
  Future<void> dismiss(String id) async {
    _activeNotifications.removeWhere(
      (RuntimeNotification entry) => entry.id == id,
    );
    notifyListeners();
  }

  @override
  Future<void> clear() async {
    if (_activeNotifications.isEmpty) {
      return;
    }
    _activeNotifications.clear();
    notifyListeners();
  }
}
