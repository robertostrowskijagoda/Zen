import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart'
    show readableInsets;
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_link.dart';
import 'package:zen/src/features/pebbles/pebble_parts.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_detail_screen.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';

/// Scans a pebble's QR code with the app's scanner and opens what it
/// carries; anything else is said to be no pebble.
Future<void> scanPebble(BuildContext context, WidgetRef ref) async {
  final String? text = await ref.read(peerQrScannerProvider).scan(context);
  if (text == null || text.trim().isEmpty || !context.mounted) {
    return;
  }
  final PebbleCard? card = pebbleCardFromLink(text);
  if (card == null) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t('To nie jest kod kamyczka.'))));
    return;
  }
  await PebbleCollectScreen.open(context, card);
}

/// A pebble found (its QR code scanned, its link opened): the stone from
/// its card, its name, note, author and date, and "Zbierz", which saves it
/// at once; the full design follows in the background.
class PebbleCollectScreen extends ConsumerStatefulWidget {
  const PebbleCollectScreen({required this.card, super.key});

  final PebbleCard card;

  static Future<void> open(BuildContext context, PebbleCard card) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => PebbleCollectScreen(card: card),
        ),
      );

  @override
  ConsumerState<PebbleCollectScreen> createState() =>
      _PebbleCollectScreenState();
}

class _PebbleCollectScreenState extends ConsumerState<PebbleCollectScreen> {
  final TextEditingController _note = TextEditingController();
  late final Future<bool> _valid = widget.card.verify();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _collect(PebbleService service) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final PebbleCollectResult result = await service.collect(
      widget.card,
      findNote: _note.text,
    );
    if (!mounted) {
      return;
    }
    switch (result) {
      case PebbleCollectResult.invalid:
        setState(() {
          _busy = false;
          _error = t(
            'Podpis tego kamyczka się nie zgadza. Ktoś mógł go podrobić, '
            'więc nie trafi do kolekcji.',
          );
        });
        return;
      case PebbleCollectResult.full:
        setState(() {
          _busy = false;
          _error = t(
            'Kolekcja jest pełna. Usuń któryś kamyczek, żeby zebrać nowy.',
          );
        });
        return;
      case PebbleCollectResult.collected:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(t('Zebrano! Pełny wygląd kamyczka dotrze w tle.')),
          ),
        );
      case PebbleCollectResult.already || PebbleCollectResult.own:
        break;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            PebbleDetailScreen(card: widget.card),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PebbleService? service = ref.watch(pebbleServiceProvider);
    final PebbleCard card = widget.card;
    final PebbleEntry? had = service?.store.entry(card.id);
    return Scaffold(
      key: const Key('pebble-collect-screen'),
      appBar: ZenSectionBar(title: t('Znaleziony kamyczek')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: readableInsets(context, bottom: 32),
          children: <Widget>[
            const SizedBox(height: 12),
            Center(
              child: PebbleView(
                design: null,
                card: card,
                size: 220,
                interactive: true,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              card.name.isEmpty ? t('Kamyczek') : card.name,
              textAlign: TextAlign.center,
              style: zen.display(
                color: zen.textPrimary,
                size: 24,
                weight: FontWeight.w600,
              ),
            ),
            if (card.note.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                card.note,
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textSecondary, fontSize: 15),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              t('{author} · {date}', <String, Object?>{
                'author': card.authorName.isEmpty
                    ? t('Autor nieznany')
                    : card.authorName,
                'date': ZenFormat.date(card.created),
              }),
              textAlign: TextAlign.center,
              style: TextStyle(color: zen.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 20),
            FutureBuilder<bool>(
              future: _valid,
              builder: (BuildContext context, AsyncSnapshot<bool> valid) {
                if (valid.data == false) {
                  return ZenInfo(
                    key: const Key('pebble-collect-invalid'),
                    icon: Icons.gpp_bad_outlined,
                    tone: zen.danger,
                    text: t(
                      'Podpis tego kamyczka się nie zgadza. Ktoś mógł go '
                      'podrobić, więc nie da się go zebrać.',
                    ),
                  );
                }
                if (service == null) {
                  return ZenInfo(
                    text: t(
                      'Kamyczki będzie można zbierać, gdy Zen skończy się '
                      'uruchamiać.',
                    ),
                  );
                }
                if (had != null && (had.collected || had.created)) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      ZenInfo(
                        icon: Icons.check_circle_outline_rounded,
                        text: had.created
                            ? t('To Twój kamyczek.')
                            : t('Ten kamyczek jest już w Twojej kolekcji.'),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        key: const Key('pebble-collect-show'),
                        onPressed: () => unawaited(_collect(service)),
                        child: Text(t('Pokaż')),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    TextField(
                      key: const Key('pebble-collect-note'),
                      controller: _note,
                      maxLength: kPebbleFindNoteMaxChars,
                      minLines: 1,
                      maxLines: 3,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: t('Gdzie go znalazłeś(-aś)? (opcjonalnie)'),
                        hintText: t('np. pod mostem na bulwarach'),
                        helperText: t('Widzą to Twoi znajomi.'),
                        prefixIcon: const Icon(Icons.place_outlined),
                      ),
                    ),
                    if (_error != null) ...<Widget>[
                      const SizedBox(height: 8),
                      Text(_error!, style: TextStyle(color: zen.danger)),
                    ],
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('pebble-collect-button'),
                      onPressed: _busy || valid.data != true
                          ? null
                          : () => unawaited(_collect(service)),
                      icon: const Icon(Icons.back_hand_outlined),
                      label: Text(t('Zbierz')),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      t(
                        'Kamyczek zostaje na miejscu: każdy, kto go znajdzie, '
                        'może go zebrać.',
                      ),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
