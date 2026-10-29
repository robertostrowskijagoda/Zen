import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/qr_sticker/presentation/sticker_designer_screen.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';

/// The sticker designer with a pebble's link. Until the designer has its
/// own pebble kind (with the pebble mark), the code goes out as the page
/// sticker; swapping it is one line in `pebble_parts.dart`.
Future<void> openPebbleSticker(
  BuildContext context, {
  required String link,
  required String name,
  required String author,
}) => StickerDesignerScreen.open(context, <StickerSubject>[
  StickerSubject(
    kind: StickerKind.zenAbout,
    data: link,
    label: t('Kamyczek'),
    name: name,
  ),
]);
