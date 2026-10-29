import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_link.dart';
import 'package:zen/src/features/qr_sticker/presentation/sticker_designer_screen.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';

/// The sticker designer with a pebble's link. Until the designer has its
/// own pebble kind (with the pebble mark), the code goes out as the page
/// sticker; swapping it is one line in `pebble_parts.dart`.
Future<void> openPebbleSticker(BuildContext context, PebbleCard card) =>
    StickerDesignerScreen.open(context, <StickerSubject>[
      StickerSubject(
        kind: StickerKind.zenAbout,
        data: pebbleWebLink(card),
        label: t('Kamyczek'),
        name: card.name,
      ),
    ]);
