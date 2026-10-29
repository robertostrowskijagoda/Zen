import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

// Every QR code scanned in the app goes through here. Zen's links keep the
// github.io address, so a phone's own camera opens their page (which opens
// Zen or shows how to get it); scanned in Zen they go straight to their
// screen, never to the browser: an invitation to adding the friend, a door
// sticker to knocking, a pebble to collecting, Zen's pages to their screen
// in the app, a zen:// link to wherever it leads.

int _scans = 0;

/// The in-app route of a scanned or pasted [text] when it is a Zen link
/// (any form [runtimeRouteIntentFromRouteKey] reads: the invitation page
/// with a code, `…/m#<door>`, `…/k/#<pebble>`, the install, about and other
/// pages, `zen-flat:` and `zen://` links); `null` for anything else.
RuntimeRouteIntent? zenLinkIntent(String? text) {
  final String? trimmed = text?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  return runtimeRouteIntentFromRouteKey(
    id: 'scan-${_scans++}',
    routeKey: trimmed,
  );
}

/// Opens [text] in the app when it is a Zen link (the screen of its
/// [zenLinkIntent], over whatever is open); whether it was one.
bool openZenLink(WidgetRef ref, String? text) {
  if (zenLinkIntent(text) == null) {
    return false;
  }
  unawaited(
    ref
        .read(socialHubControllerProvider.notifier)
        .requestLaunchFromRouteKey(text!.trim()),
  );
  return true;
}

/// Scans a QR code with the app's scanner for a screen that wants what
/// [accepts] takes: that comes back. Any other Zen link opens its own
/// screen in the app ([openZenLink]) and `null` comes back; anything else
/// comes back as it is, for the screen's own "this is not …" message.
Future<String?> scanZenCode(
  BuildContext context,
  WidgetRef ref, {
  required bool Function(String text) accepts,
}) async {
  final String? text = await ref.read(peerQrScannerProvider).scan(context);
  return routeScannedText(ref, text, accepts: accepts);
}

/// [text] as [scanZenCode] hands it on (also for a pasted code).
String? routeScannedText(
  WidgetRef ref,
  String? text, {
  required bool Function(String text) accepts,
}) {
  final String? trimmed = text?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (accepts(trimmed)) {
    return trimmed;
  }
  return openZenLink(ref, trimmed) ? null : trimmed;
}
