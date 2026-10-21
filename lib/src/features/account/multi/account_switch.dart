import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// What the app opens next: the account and, when its password was already
/// checked, its security service, unlocked.
@immutable
final class ZenAccountOpening {
  const ZenAccountOpening({required this.scope, this.security});

  final ZenAccountScope scope;

  /// Unlocked for [scope] (its password checked before the switch), so
  /// the account opens without a second lock screen; `null`: it starts as
  /// the app does (locked when it has a password).
  final AppSecurityService? security;
}

/// Where the app's root hears that another account should open: it then
/// throws the current providers away and starts the app again for that
/// account (in this process, on the same screen).
final class ZenAccountHost extends ChangeNotifier {
  ZenAccountHost();

  /// The app's own.
  static final ZenAccountHost instance = ZenAccountHost();

  ZenAccountOpening? _pending;
  bool _switching = false;

  /// Between leaving one account and the next one being up: a lock
  /// noticed meanwhile is part of the switch, not a reason for another.
  bool get switching => _switching;

  /// Leaving the current account has started.
  void begin() {
    _switching = true;
  }

  /// Asks the app's root to open [opening].
  void request(ZenAccountOpening opening) {
    _switching = true;
    _pending = opening;
    notifyListeners();
  }

  /// The opening asked for, once (the app's root).
  ZenAccountOpening? take() {
    final ZenAccountOpening? pending = _pending;
    _pending = null;
    return pending;
  }

  /// The next account is up.
  void settled() {
    _switching = false;
  }
}

final Provider<ZenAccountHost> zenAccountHostProvider =
    Provider<ZenAccountHost>((Ref ref) => ZenAccountHost.instance);

final Provider<ZenAccountRegistry> zenAccountRegistryProvider =
    Provider<ZenAccountRegistry>((Ref ref) => ZenAccountRegistry());

/// The security service of an additional account, on its own entries in
/// the secret store and the shared hardware key ([SharedKeyVault]).
typedef ZenAccountSecurityFactory =
    AppSecurityService Function(ZenAccountScope scope);

AppSecurityService defaultZenAccountSecurity(ZenAccountScope scope) =>
    LocalAppSecurityService(
      credentialsStore: SecureStorageCredentialsStore.account(scope.secret),
      keyVault: scope.isDefault
          ? platformKeyVault()
          : SharedKeyVault(platformKeyVault()),
    );

final Provider<ZenAccountSecurityFactory> zenAccountSecurityFactoryProvider =
    Provider<ZenAccountSecurityFactory>((Ref ref) => defaultZenAccountSecurity);

/// How a password for another account went.
enum ZenAccountUnlock {
  /// Right: the account opens.
  opened,

  /// Wrong ID or wrong password (never told apart).
  refused,

  /// The account's panic password: the account was wiped, silently.
  wiped,
}

/// The outcome of [unlockZenAccount].
@immutable
final class ZenAccountUnlockResult {
  const ZenAccountUnlockResult(this.outcome, [this.security]);

  final ZenAccountUnlock outcome;

  /// Unlocked, for [ZenAccountOpening.security].
  final AppSecurityService? security;
}

/// Checks [password] for the account [scope] before anything is switched:
/// right — its security service comes back unlocked; its panic password —
/// the account is wiped ([ZenAccountRegistry.wipeAccount]) and it reads as
/// refused to whoever watches. An account that never got a password (its
/// first start was cut short) opens as it is and asks for one.
Future<ZenAccountUnlockResult> unlockZenAccount(
  ZenAccountScope scope,
  String password, {
  required ZenAccountRegistry registry,
  ZenAccountSecurityFactory security = defaultZenAccountSecurity,
}) async {
  final AppSecurityService service = security(scope);
  await service.initialize(settings: const AppSettings());
  if (!service.hasPassword) {
    return ZenAccountUnlockResult(ZenAccountUnlock.opened, service);
  }
  if (await service.matchesPanicPassword(password) &&
      !await service.verifyPassword(password)) {
    if (!scope.isDefault) {
      await registry.wipeAccount(scope);
    }
    return const ZenAccountUnlockResult(ZenAccountUnlock.wiped);
  }
  if (!await service.unlock(password)) {
    return const ZenAccountUnlockResult(ZenAccountUnlock.refused);
  }
  return ZenAccountUnlockResult(ZenAccountUnlock.opened, service);
}

/// Stops what runs for the current account — its modules, its mesh node,
/// its notifications — and drops its key from memory, before another
/// account opens. The Android background service is left alone: it
/// serves the default account only, whatever is on screen.
///
/// Everything is read from [ref] before the first wait, so a sheet or a
/// page that is closing may call it.
Future<void> leaveZenAccount(WidgetRef ref) {
  final ZenAccountHost host = ref.read(zenAccountHostProvider);
  final ZenCore core = ref.read(zenCoreProvider);
  final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
  final RuntimeSystemNotificationService notices = ref.read(
    runtimeSystemNotificationServiceProvider,
  );
  final AppSecurityService security = ref.read(appSecurityServiceProvider);
  return _leave(host, core, runtime, notices, security);
}

Future<void> _leave(
  ZenAccountHost host,
  ZenCore core,
  RuntimeNodeRuntime runtime,
  RuntimeSystemNotificationService notices,
  AppSecurityService security,
) async {
  host.begin();
  try {
    await core.stop();
  } on Object catch (error, stackTrace) {
    logZenError(
      'Stopping the account before a switch failed',
      error,
      stackTrace,
    );
  }
  try {
    await runtime.stop();
  } on Object catch (error, stackTrace) {
    logZenError('Stopping the node before a switch failed', error, stackTrace);
  }
  try {
    // Nothing of this account stays in the shade.
    await notices.clear();
  } on Object catch (error, stackTrace) {
    logZenError(
      'Clearing notifications before a switch failed',
      error,
      stackTrace,
    );
  }
  security.lock();
}

/// Leaves the current account and opens [opening] (read from [ref] at
/// once, like [leaveZenAccount]).
Future<void> switchZenAccount(WidgetRef ref, ZenAccountOpening opening) async {
  final ZenAccountHost host = ref.read(zenAccountHostProvider);
  await leaveZenAccount(ref);
  host.request(opening);
}

/// Back to the default account, locked: what locking an additional
/// account does (its own lock screen would show that it exists).
Future<void> returnToDefaultZenAccount(WidgetRef ref) => switchZenAccount(
  ref,
  const ZenAccountOpening(scope: ZenAccountScope.defaultAccount),
);
