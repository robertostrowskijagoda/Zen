import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Keychain items get "this device only, after the first unlock";
/// the items written before keep working and are moved over.
void main() {
  setUp(SecureStorageCredentialsStore.debugForgetKeychainMove);
  tearDown(() {
    SecureStorageCredentialsStore.debugForgetKeychainMove();
    debugDefaultTargetPlatformOverride = null;
  });

  group('iOS', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    for (final bool byAccessibility in <bool>[true, false]) {
      final String plugin = byAccessibility
          ? 'a keychain matched by accessibility'
          : 'a keychain that ignores it';
      test(
        'items written before are moved to this device only ($plugin)',
        () async {
          final _Keychain keychain =
              _Keychain(matchesByAccessibility: byAccessibility)
                ..items.addAll(<String, (String, String)>{
                  appSecurityPasswordHashStorageKey: ('hash', _earlier),
                  appSecurityWrappedMasterKeyStorageKey: ('wrapped', _earlier),
                });
          final SecureStorageCredentialsStore store =
              SecureStorageCredentialsStore(
                keychain.view(_now),
                keychain.view(_earlier),
              );

          expect(await store.read(appSecurityPasswordHashStorageKey), 'hash');
          expect(keychain.items[appSecurityPasswordHashStorageKey], (
            'hash',
            _now,
          ));
          // Moved without being read (all of them, at the first use).
          expect(keychain.items[appSecurityWrappedMasterKeyStorageKey], (
            'wrapped',
            _now,
          ));
          expect(
            await store.read(appSecurityWrappedMasterKeyStorageKey),
            'wrapped',
          );
          expect(
            keychain
                .items[SecureStorageCredentialsStore.keychainMovedMarkerKey]
                ?.$1,
            '1',
          );

          await store.write(appSecurityPasswordHashStorageKey, 'new-hash');
          expect(
            await store.read(appSecurityPasswordHashStorageKey),
            'new-hash',
          );
          expect(keychain.items[appSecurityPasswordHashStorageKey], (
            'new-hash',
            _now,
          ));
        },
      );
    }

    test('a move cut short gets the item back from its copy', () async {
      const String copy = 'zen_rewrite_keychain_moving:';
      final _Keychain keychain = _Keychain(matchesByAccessibility: true)
        ..items['$copy$appSecurityWrappedMasterKeyStorageKey'] = (
          'wrapped',
          _now,
        );
      final SecureStorageCredentialsStore store = SecureStorageCredentialsStore(
        keychain.view(_now),
        keychain.view(_earlier),
      );
      expect(
        await store.read(appSecurityWrappedMasterKeyStorageKey),
        'wrapped',
      );
      expect(
        keychain.items.keys.where((String key) => key.startsWith(copy)),
        isEmpty,
      );
    });

    test('an item the move missed is still found, and moved', () async {
      final _Keychain keychain = _Keychain(matchesByAccessibility: true);
      final SecureStorageCredentialsStore store = SecureStorageCredentialsStore(
        keychain.view(_now),
        keychain.view(_earlier),
      );
      expect(await store.read('zen_other'), isNull);
      // Written by an older copy of the app after the move ran.
      keychain.items['zen_other'] = ('x', _earlier);
      expect(await store.read('zen_other'), 'x');
      expect(keychain.items['zen_other'], ('x', _now));
    });

    test('a write refused for another reason keeps the old value', () async {
      final _Keychain keychain = _Keychain(matchesByAccessibility: true)
        ..items[appSecurityPasswordHashStorageKey] = ('hash', _now);
      final _KeychainView now = keychain.view(_now);
      final SecureStorageCredentialsStore store = SecureStorageCredentialsStore(
        now,
        keychain.view(_earlier),
      );
      expect(await store.read(appSecurityPasswordHashStorageKey), 'hash');
      now.refuseWrites = PlatformException(
        code: 'Unexpected security result code',
        message: 'Code: -25308, Message: User interaction is not allowed.',
      );
      await expectLater(
        store.write(appSecurityPasswordHashStorageKey, 'other'),
        throwsA(isA<PlatformException>()),
      );
      expect(keychain.items[appSecurityPasswordHashStorageKey], ('hash', _now));
    });

    test('deleting removes the copy of either accessibility', () async {
      final _Keychain keychain = _Keychain(matchesByAccessibility: true);
      final SecureStorageCredentialsStore store = SecureStorageCredentialsStore(
        keychain.view(_now),
        keychain.view(_earlier),
      );
      await store.write('zen_a', 'a');
      keychain.items['zen_b'] = ('b', _earlier);
      await store.delete('zen_a');
      await store.delete('zen_b');
      expect(await store.read('zen_a'), isNull);
      expect(await store.read('zen_b'), isNull);
      expect(keychain.items.keys, <String>[
        SecureStorageCredentialsStore.keychainMovedMarkerKey,
      ]);
    });
  });

  test('macOS: a refused write is replaced, with the earlier attributes '
      'as the last resort', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final _Keychain keychain = _Keychain(matchesByAccessibility: false);
    final _KeychainView now = keychain.view(_now)
      ..refuseWrites = PlatformException(code: 'duplicate', message: '-25299');
    final SecureStorageCredentialsStore store = SecureStorageCredentialsStore(
      now,
      keychain.view(_earlier),
    );
    await store.write('zen_key', 'value');
    expect(await store.read('zen_key'), 'value');
    expect(keychain.items['zen_key'], ('value', _earlier));
    // Nothing is moved on a Mac (the login keychain takes no notice).
    expect(
      keychain.items.containsKey(
        SecureStorageCredentialsStore.keychainMovedMarkerKey,
      ),
      isFalse,
    );
  });

  test('Android: the store passes straight through', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final _Keychain keychain = _Keychain(matchesByAccessibility: true);
    final _KeychainView now = keychain.view(_now);
    final SecureStorageCredentialsStore store = SecureStorageCredentialsStore(
      now,
      keychain.view(_earlier),
    );
    await store.write('zen_key', 'value');
    expect(await store.read('zen_key'), 'value');
    now.refuseWrites = PlatformException(code: 'x', message: '-25299');
    await expectLater(
      store.write('zen_key', 'other'),
      throwsA(isA<PlatformException>()),
    );
    expect(keychain.items['zen_key'], ('value', _now));
    expect(keychain.items.length, 1);
  });
}

const String _now = 'first_unlock_this_device';
const String _earlier = 'unlocked';

/// One keychain, as the plugin sees it with one accessibility or another.
final class _Keychain {
  _Keychain({required this.matchesByAccessibility});

  /// Whether lookups take the accessibility into account (then an item of
  /// another one is invisible, and adding it again fails as a duplicate).
  final bool matchesByAccessibility;

  /// Key → (value, accessibility).
  final Map<String, (String, String)> items = <String, (String, String)>{};

  _KeychainView view(String accessibility) =>
      _KeychainView(this, accessibility);
}

final class _KeychainView implements SecureKeyValueBackend {
  _KeychainView(this.keychain, this.accessibility);

  final _Keychain keychain;
  final String accessibility;
  PlatformException? refuseWrites;

  bool _sees(String key) {
    final (String, String)? item = keychain.items[key];
    return item != null &&
        (!keychain.matchesByAccessibility || item.$2 == accessibility);
  }

  @override
  Future<String?> read(String key) async =>
      _sees(key) ? keychain.items[key]!.$1 : null;

  @override
  Future<void> write(String key, String value) async {
    final PlatformException? refusal = refuseWrites;
    if (refusal != null) {
      throw refusal;
    }
    if (keychain.items.containsKey(key) && !_sees(key)) {
      throw PlatformException(
        code: 'Unexpected security result code',
        message:
            'Code: -25299, Message: The specified item already exists in '
            'the keychain.',
      );
    }
    keychain.items[key] = (value, accessibility);
  }

  @override
  Future<void> delete(String key) async {
    if (_sees(key)) {
      keychain.items.remove(key);
    }
  }

  @override
  Future<Map<String, String>> readAll() async => <String, String>{
    for (final MapEntry<String, (String, String)> item
        in keychain.items.entries)
      if (_sees(item.key)) item.key: item.value.$1,
  };
}
