import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_fixed.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_link.dart';
import 'package:zen/src/features/qr_sticker/presentation/zen_qr_view.dart';

/// "Pokaż kod": a pebble's QR code across the whole screen, black on
/// white, for someone else to scan from this phone — in Zen (straight to
/// collecting) or with the phone's camera (the pebble's page). It carries
/// the same link as the printed sticker ([pebbleWebLink]).
class PebbleCodeScreen extends StatelessWidget {
  const PebbleCodeScreen({required this.card, super.key});

  final PebbleCard card;

  static Future<void> open(BuildContext context, PebbleCard card) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => PebbleCodeScreen(card: card),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final String link = pebbleWebLink(card);
    return Scaffold(
      key: const Key('pebble-code-screen'),
      backgroundColor: ZenFixed.qrPaper,
      // Dark type on the white page in every theme.
      appBar: zenFixedAppBar(
        context,
        background: ZenFixed.qrPaper,
        foreground: ZenFixed.qrInk,
        title: Text(
          card.name.isEmpty ? t('Kamyczek') : card.name,
          key: const Key('pebble-code-title'),
        ),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final double side = math.min(box.maxWidth - 16, box.maxHeight - 96);
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Center(
                  child: ZenQrView(
                    key: const Key('pebble-code-qr'),
                    data: link,
                    size: math.max(120, side),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    t(
                      'Niech ktoś zeskanuje ten kod w Zen albo aparatem '
                      'telefonu.',
                    ),
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: ZenFixed.qrInk,
                      fontSize: 15,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
