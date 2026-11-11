import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';

/// The system clipboard as Android 10+ shows it to Zen: an app that is not
/// in front reads nothing (getPrimaryClip gives null) but may still write.
final class _AndroidClipboard implements ClipboardAccess {
  String? text;
  bool inFront = true;
  int reads = 0;

  @override
  Future<String?> read() async {
    reads++;
    return inFront ? text : null;
  }

  @override
  Future<void> write(String value) async => text = value;
}

void main() {
  group('on a phone that hides the clipboard from the background', () {
    test('a secret copied before leaving Zen is gone at the lock, without '
        'Zen coming back', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final _AndroidClipboard system = _AndroidClipboard();
      final ExpiringClipboard clipboard = ExpiringClipboard(
        access: system,
        isInForeground: () => system.inFront,
      );
      const String key = 'zen-key-ABCD-EFGH-IJKL';
      await clipboard.copy(key);
      expect(system.text, key);
      // The person leaves Zen and the background lock fires.
      system.inFront = false;
      await clipboard.clearNow();
      expect(system.text, '');
      expect(clipboard.pendingText, isNull);
    });

    test('and at the end of its time, in the background', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final _AndroidClipboard system = _AndroidClipboard();
      final ExpiringClipboard clipboard = ExpiringClipboard(
        access: system,
        isInForeground: () => system.inFront,
      );
      const String key = 'zen-key-ABCD-EFGH-IJKL';
      await clipboard.copy(key, ttl: const Duration(milliseconds: 50));
      system.inFront = false;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(system.text, '');
      expect(clipboard.pendingText, isNull);
    });

    test("the system's own call empties it when there is one", () async {
      final _AndroidClipboard system = _AndroidClipboard();
      int cleared = 0;
      final ExpiringClipboard clipboard = ExpiringClipboard(
        access: system,
        isInForeground: () => system.inFront,
        backgroundHidesClipboard: () => true,
        clearSystem: () async {
          cleared++;
          system.text = null;
          return true;
        },
      );
      await clipboard.copy('klucz');
      system.inFront = false;
      await clipboard.clearNow();
      expect(cleared, 1);
      expect(system.text, isNull, reason: 'emptied, not overwritten');
      expect(clipboard.pendingText, isNull);
    });

    test('something copied in Zen after the secret, seen as Zen is left, '
        'is not wiped from the background', () async {
      final _AndroidClipboard system = _AndroidClipboard();
      final ExpiringClipboard clipboard = ExpiringClipboard(
        access: system,
        isInForeground: () => system.inFront,
        backgroundHidesClipboard: () => true,
      );
      await clipboard.copy('klucz');
      // A message text copied in Zen with the text selection.
      system.text = 'zwykły tekst';
      clipboard.didChangeAppLifecycleState(AppLifecycleState.resumed);
      clipboard.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(clipboard.pendingText, isNull);
      system.inFront = false;
      await clipboard.clearNow();
      expect(system.text, 'zwykły tekst');
    });

    test('the clipboard is not looked at on the way back in', () async {
      final _AndroidClipboard system = _AndroidClipboard();
      final ExpiringClipboard clipboard = ExpiringClipboard(
        access: system,
        isInForeground: () => system.inFront,
        backgroundHidesClipboard: () => true,
      );
      await clipboard.copy('klucz');
      clipboard.didChangeAppLifecycleState(AppLifecycleState.hidden);
      final int before = system.reads;
      // Coming back: hidden, inactive, resumed. Reading what another app
      // copied meanwhile would show the system's "pasted" notice.
      clipboard.didChangeAppLifecycleState(AppLifecycleState.inactive);
      await Future<void>.delayed(Duration.zero);
      expect(system.reads, before);
      await clipboard.clearNow();
    });

    test('a failed clearing keeps the secret, cleared at the next change of '
        'the app', () async {
      final _AndroidClipboard system = _AndroidClipboard();
      bool fails = false;
      final ExpiringClipboard clipboard = ExpiringClipboard(
        access: _FailingWrites(system, () => fails),
        isInForeground: () => system.inFront,
        backgroundHidesClipboard: () => true,
      );
      await clipboard.copy('klucz');
      fails = true;
      system.inFront = false;
      await clipboard.clearNow();
      expect(system.text, 'klucz');
      expect(clipboard.pendingText, 'klucz');
      fails = false;
      clipboard.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(system.text, '');
      expect(clipboard.pendingText, isNull);
    });
  });

  group(
    'a secret never goes to the plain clipboard where it can be marked',
    () {
      test('a failed marked copy copies nothing and says so', () async {
        final _AndroidClipboard system = _AndroidClipboard()
          ..text = 'wcześniej';
        final ExpiringClipboard clipboard = ExpiringClipboard(
          access: system,
          isInForeground: () => true,
          writeSensitive: (String text) async => false,
        );
        expect(await clipboard.copy('klucz'), isFalse);
        expect(system.text, 'wcześniej');
        expect(clipboard.pendingText, isNull);
      });

      test('where the system has no marked copy, the plain clipboard is '
          'used', () async {
        final _AndroidClipboard system = _AndroidClipboard();
        final ExpiringClipboard clipboard = ExpiringClipboard(
          access: system,
          isInForeground: () => true,
          writeSensitive: (String text) async => null,
        );
        expect(await clipboard.copy('klucz'), isTrue);
        expect(system.text, 'klucz');
        await clipboard.clearNow();
      });

      for (final (TargetPlatform platform, String channel)
          in <(TargetPlatform, String)>[
            (TargetPlatform.android, 'zen/system'),
            (TargetPlatform.windows, 'zen/clipboard'),
          ]) {
        test('${platform.name}: a refusal of the system is a failure, not a '
            'plain copy; the clipboard is emptied by the system', () async {
          TestWidgetsFlutterBinding.ensureInitialized();
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          final List<String> calls = <String>[];
          bool answers = true;
          final TestDefaultBinaryMessenger messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(MethodChannel(channel), (
            MethodCall call,
          ) async {
            calls.add(call.method);
            if (!answers) {
              throw PlatformException(code: 'clipboard');
            }
            return true;
          });
          addTearDown(
            () => messenger.setMockMethodCallHandler(
              MethodChannel(channel),
              null,
            ),
          );
          expect(await writeMarkedSecret('klucz'), isTrue);
          expect(await clearSystemClipboard(), isTrue);
          expect(calls, <String>['copySensitive', 'clearSensitive']);
          answers = false;
          expect(await writeMarkedSecret('klucz'), isFalse);
          expect(await clearSystemClipboard(), isFalse);
        });
      }

      test('linux, macOS and iOS have no marked copy: null, the plain '
          'clipboard', () async {
        for (final TargetPlatform platform in <TargetPlatform>[
          TargetPlatform.linux,
          TargetPlatform.macOS,
          TargetPlatform.iOS,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          try {
            expect(await writeMarkedSecret('klucz'), isNull);
            expect(await clearSystemClipboard(), isFalse);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        }
      });
    },
  );

  test('text from notes and reports is copied through the secure '
      'clipboard; only public links use the plain one', () {
    const Set<String> plainAllowed = <String>{
      // Public web addresses: the store page, the donation page, a legal
      // document's page.
      'lib/src/features/about/presentation/about_screen.dart',
      'lib/src/features/about/presentation/legal_document_screen.dart',
      'lib/src/features/update/presentation/store_share_dialog.dart',
      'lib/src/core/utils/secure_clipboard.dart',
    };
    final List<String> plain = <String>[
      for (final FileSystemEntity entity in Directory(
        'lib',
      ).listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            entity.readAsStringSync().contains('Clipboard.setData('))
          entity.path.replaceAll(r'\', '/'),
    ];
    expect(plain.toSet().difference(plainAllowed), isEmpty);
  });
}

/// [inner] whose writes fail while [fails] says so.
final class _FailingWrites implements ClipboardAccess {
  _FailingWrites(this.inner, this.fails);

  final ClipboardAccess inner;
  final bool Function() fails;

  @override
  Future<String?> read() => inner.read();

  @override
  Future<void> write(String text) async {
    if (fails()) {
      throw PlatformException(code: 'clipboard');
    }
    await inner.write(text);
  }
}
