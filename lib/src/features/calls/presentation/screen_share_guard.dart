import 'dart:io';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/call_safety_cues.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';

/// Reads the Android API level (null elsewhere); replaceable in tests.
Future<int?> Function() screenShareAndroidSdkReader = loadAndroidSdkInt;

/// Whether this platform is Android; replaceable in tests.
bool Function() screenShareIsAndroid = () => Platform.isAndroid;

/// Before sharing starts: on Android older than 14 the system cannot share a
/// single app, so the person is told that the WHOLE screen goes out.
/// Returns false when they back out.
Future<bool> confirmScreenShareStart(BuildContext context) async {
  final bool android = screenShareIsAndroid();
  final int? sdk = android ? await screenShareAndroidSdkReader() : null;
  if (!screenShareNeedsWholeScreenWarning(
    isAndroid: android,
    androidSdkInt: sdk,
  )) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      key: const Key('screen-share-whole-screen-warning'),
      title: Text(t('Udostępnisz cały ekran')),
      content: Text(
        t(
          'Na tej wersji Androida nie da się udostępnić jednej aplikacji. '
          'Druga strona zobaczy wszystko, co jest na ekranie, także '
          'powiadomienia i kody SMS.',
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('screen-share-warning-cancel'),
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('screen-share-warning-continue'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(t('Udostępnij')),
        ),
      ],
    ),
  );
  return go ?? false;
}

/// The reminder shown for as long as this device shares its screen.
class ScreenShareReminderBanner extends StatelessWidget {
  const ScreenShareReminderBanner({required this.zen, super.key});

  final ZenColors zen;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('screen-share-reminder'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: zen.danger.withValues(alpha: 0.12),
        borderRadius: context.zenRadius(16),
        border: Border.all(color: zen.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.screen_share_rounded, size: 18, color: zen.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t(
                'Udostępniasz cały ekran — widać wszystko, także powiadomienia',
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: zen.danger,
                fontWeight: FontWeight.w700,
                fontSize: 13.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
