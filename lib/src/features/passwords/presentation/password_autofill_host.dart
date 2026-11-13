import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/passwords/password_autofill_bridge.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_autofill_screen.dart';
import 'package:zen/src/features/passwords/presentation/password_vault_widgets.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/sensitive_access.dart';

/// Answers another app's autofill request ([PasswordAutofillBridge]): asks
/// who the person is once (as opening "Hasła" does, every time; when Zen
/// was locked and the lock screen was passed while the request waited, that
/// unlock was the question, [AutofillUnlockPass]), shows the picker
/// ([PasswordAutofillScreen]) and hands over the entry tapped there, or
/// ends the request with nothing filled.
///
/// In the app's first screen, which is only built past the lock screen and
/// the first-start setup: a request that came while Zen was locked waits
/// (on the Android side, for its minute) until Zen is unlocked. Zen locking
/// takes this screen away, and with it any request it was answering, which
/// then ends with nothing filled. A request the Android side ended (its
/// time ran out, the person went back to the app, a newer one came) closes
/// the picker; but while a new login for it is being typed, the form stays
/// open: saved, the login is kept, and the person is told the form was not
/// filled.
class PasswordAutofillHost extends ConsumerStatefulWidget {
  const PasswordAutofillHost({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<PasswordAutofillHost> createState() =>
      _PasswordAutofillHostState();
}

class _PasswordAutofillHostState extends ConsumerState<PasswordAutofillHost> {
  late final PasswordAutofillBridge _bridge = ref.read(
    passwordAutofillBridgeProvider,
  );

  /// The request being answered.
  PasswordAutofillRequest? _active;

  /// The last request answered here (never taken up twice).
  String? _answeredId;

  Route<PasswordEntry>? _picker;
  PasswordAutofillSession? _session;
  NavigatorState? _navigator;
  bool _checking = false;
  bool _again = false;

  @override
  void initState() {
    super.initState();
    if (!_bridge.supported) {
      return;
    }
    _bridge.changes.addListener(_onChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _onChanged());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigator = Navigator.maybeOf(context);
  }

  @override
  void dispose() {
    _bridge.changes.removeListener(_onChanged);
    final PasswordAutofillRequest? active = _active;
    _active = null;
    if (active != null) {
      // Locked (or the app built anew) while answering: nothing is filled.
      unawaited(_bridge.cancel(active));
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      unawaitedLogged(_check(), context: 'Checking an autofill request failed');
    }
  }

  Future<void> _check() async {
    if (_checking) {
      _again = true;
      return;
    }
    _checking = true;
    try {
      do {
        _again = false;
        final PasswordAutofillRequest? pending = await _bridge.pending();
        if (!mounted) {
          return;
        }
        final PasswordAutofillRequest? active = _active;
        if (active != null && pending?.id != active.id) {
          _active = null;
          _answeredId = active.id;
          final PasswordAutofillSession? session = _session;
          _session = null;
          if (session != null && session.editing) {
            // Ended while a new login for it is typed: the form stays, and
            // the picker under it goes once the form is done.
            session.ended = true;
            _picker = null;
          } else {
            // Ended on the Android side: the picker goes.
            _closePicker();
          }
        }
        if (pending != null && _active == null && pending.id != _answeredId) {
          unawaitedLogged(
            _answer(pending),
            context: 'Answering an autofill request failed',
          );
        } else {
          // Nothing to take up: an unlock passed for a request that ended
          // meanwhile is left to nobody.
          ref.read(autofillUnlockPassProvider).forget();
        }
      } while (_again && mounted);
    } finally {
      _checking = false;
    }
  }

  bool _still(PasswordAutofillRequest request) =>
      mounted && identical(_active, request);

  Future<void> _answer(PasswordAutofillRequest request) async {
    _active = request;
    // Once per request. Zen was locked when it came and the lock screen was
    // passed for it: that was the question. Otherwise it is asked here, as
    // for opening "Hasła": a confirmation a moment ago (or an unlock for
    // anything else) does not count.
    ref.read(sensitiveAccessClockProvider).forget();
    final bool confirmed =
        ref.read(autofillUnlockPassProvider).take(request.id) ||
        await confirmSensitiveAccess(
          context,
          reason: t('Hasła są chronione. Potwierdź, że to Ty.'),
        );
    if (!_still(request)) {
      return;
    }
    final NavigatorState? navigator = _navigator;
    if (!confirmed || navigator == null || !navigator.mounted) {
      await _end(request, null);
      return;
    }
    final PasswordAutofillSession session = PasswordAutofillSession();
    final Route<PasswordEntry> route = MaterialPageRoute<PasswordEntry>(
      settings: const RouteSettings(name: kPasswordVaultRouteName),
      builder: (BuildContext context) =>
          PasswordAutofillScreen(request: request, session: session),
    );
    _picker = route;
    _session = session;
    final PasswordEntry? chosen = await navigator.push(route);
    if (identical(_picker, route)) {
      _picker = null;
    }
    if (identical(_session, session)) {
      _session = null;
    }
    if (!_still(request)) {
      return;
    }
    await _end(
      request,
      chosen,
      added: chosen != null && session.addedId == chosen.id,
    );
  }

  /// Hands [chosen] (read again from the vault: as it is now, and nothing
  /// while Zen is locked) to [request], or ends it with nothing filled.
  /// [added]: [chosen] was made for this request just now.
  Future<void> _end(
    PasswordAutofillRequest request,
    PasswordEntry? chosen, {
    bool added = false,
  }) async {
    _active = null;
    _answeredId = request.id;
    final bool locked = ref.read(appSecurityServiceProvider).isLocked;
    final PasswordEntry? entry = chosen == null || locked
        ? null
        : ref.read(passwordVaultServiceProvider).entry(chosen.id);
    if (entry == null) {
      // Closed by the person: back to the app. Locked: Zen stays.
      await _bridge.cancel(request, back: !locked);
      return;
    }
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    final bool filled = await _bridge.fill(
      request,
      login: entry.login,
      password: entry.password,
    );
    if (!filled) {
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            added
                ? passwordAutofillSavedNotFilledText()
                : t(
                    'Czas na wypełnienie minął. Spróbuj jeszcze raz w tamtej '
                    'aplikacji.',
                  ),
          ),
        ),
      );
    }
  }

  /// Takes the picker away, and whatever is open over it.
  void _closePicker() {
    final Route<PasswordEntry>? route = _picker;
    _picker = null;
    final NavigatorState? navigator = _navigator;
    if (route == null ||
        navigator == null ||
        !navigator.mounted ||
        !route.isActive) {
      return;
    }
    navigator.popUntil((Route<dynamic> r) => r == route || r.isFirst);
    if (route.isCurrent) {
      navigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
