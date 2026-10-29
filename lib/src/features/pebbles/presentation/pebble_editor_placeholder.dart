import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/render/pebble_view_placeholder.dart';

/// Stands in for the 2.5D editor until it is there (same entry point, so
/// swapping it is one line in `pebble_parts.dart`): a random stone, drawn
/// again with "Losuj".
class PebbleEditorScreen extends StatefulWidget {
  const PebbleEditorScreen({super.key});

  /// The design, the card's look and the thumbnail of the painted stone;
  /// `null` when the person leaves without one.
  static Future<(Uint8List design, PebbleCardLook look, Uint8List thumbnail)?>
  open(BuildContext context) =>
      Navigator.of(context).push<(Uint8List, PebbleCardLook, Uint8List)>(
        MaterialPageRoute<(Uint8List, PebbleCardLook, Uint8List)>(
          builder: (BuildContext context) => const PebbleEditorScreen(),
        ),
      );

  @override
  State<PebbleEditorScreen> createState() => _PebbleEditorScreenState();
}

class _PebbleEditorScreenState extends State<PebbleEditorScreen> {
  final Random _random = Random();
  late (Uint8List, PebbleCardLook, Uint8List) _stone = _draw();

  (Uint8List, PebbleCardLook, Uint8List) _draw() {
    final Uint8List design = Uint8List.fromList(
      List<int>.generate(2048, (_) => _random.nextInt(256)),
    );
    final PebbleCardLook look = PebbleCardLook(
      shapePreset: _random.nextInt(20),
      shapeSeed: _random.nextInt(1 << 32),
      material: _random.nextInt(30),
      mainColor: _random.nextInt(0x1000000),
      secondColor: _random.nextInt(0x1000000),
    );
    final Uint8List thumbnail = Uint8List(kPebbleThumbnailBytes);
    for (int i = 3; i < 48; i++) {
      thumbnail[i] = _random.nextInt(256);
    }
    for (int y = 0; y < 16; y++) {
      for (int x = 0; x < 16; x += 2) {
        final bool inside = (x - 7.5) * (x - 7.5) + (y - 7.5) * (y - 7.5) < 20;
        final int a = inside ? 1 + _random.nextInt(15) : 0;
        final int b = inside ? 1 + _random.nextInt(15) : 0;
        thumbnail[48 + y * 8 + x ~/ 2] = (a << 4) | b;
      }
    }
    return (design, look, thumbnail);
  }

  @override
  Widget build(BuildContext context) {
    final (Uint8List design, PebbleCardLook look, Uint8List thumbnail) = _stone;
    return Scaffold(
      appBar: AppBar(title: Text(t('Pomaluj kamyczek'))),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Preview(design: design, look: look, thumbnail: thumbnail),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              children: <Widget>[
                OutlinedButton.icon(
                  key: const Key('pebble-editor-random'),
                  onPressed: () => setState(() => _stone = _draw()),
                  icon: const Icon(Icons.casino_outlined),
                  label: Text(t('Losuj')),
                ),
                FilledButton.icon(
                  key: const Key('pebble-editor-done'),
                  onPressed: () => Navigator.of(context).pop(_stone),
                  icon: const Icon(Icons.check_rounded),
                  label: Text(t('Gotowe')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The stone being made, drawn as its card will show it.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.design,
    required this.look,
    required this.thumbnail,
  });

  final Uint8List design;
  final PebbleCardLook look;
  final Uint8List thumbnail;

  @override
  Widget build(BuildContext context) => PebbleView(
    design: design,
    card: PebbleCard.preview(look: look, thumbnail: thumbnail),
    size: 220,
  );
}
