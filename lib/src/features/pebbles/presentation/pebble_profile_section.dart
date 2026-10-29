import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart'
    show readableInsets;
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_parts.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_collect_flow.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_detail_screen.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_publish_flow.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// "Kamyczki" of a profile: the pebbles the person made and collected, as
/// stones to tap. One's own come from this device's store (with making and
/// scanning, and friends' requests to keep a pebble); a friend's from the
/// part of their profile sealed for friends, so nobody else sees them.
class PebbleProfileSection extends ConsumerStatefulWidget {
  const PebbleProfileSection({
    required this.account,
    required this.own,
    super.key,
  });

  /// The person's account (a friend's), or this account's own.
  final String? account;
  final bool own;

  @override
  ConsumerState<PebbleProfileSection> createState() =>
      _PebbleProfileSectionState();
}

class _PebbleProfileSectionState extends ConsumerState<PebbleProfileSection> {
  PebbleStore? _store;
  StreamSubscription<LogEntry>? _added;
  StreamSubscription<void>? _opened;
  Future<PebbleProfile?>? _friend;

  @override
  void initState() {
    super.initState();
    if (widget.own) {
      _store = ref.read(pebbleServiceProvider)?.store;
      _store?.addListener(_changed);
      unawaited(_store?.load().then((_) => _changed()));
    } else {
      final LedgerNode? node = ref.read(ledgerNodeProvider);
      _added = node?.store.added.listen((LogEntry e) {
        if (e.kind == kPebblesProfileKind && e.account == widget.account) {
          _reloadFriend();
        }
      });
      _opened = node?.openedChanges.listen((_) => _reloadFriend());
      _reloadFriend();
    }
  }

  void _reloadFriend() {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    final String? account = widget.account;
    final PebbleProfile? raw = node == null || account == null
        ? null
        : readPebbleProfile(node, account);
    final Future<PebbleProfile?> next = raw == null
        ? Future<PebbleProfile?>.value()
        : verifyPebbleProfile(raw, account!);
    if (mounted) {
      setState(() => _friend = next);
    } else {
      _friend = next;
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _store?.removeListener(_changed);
    unawaited(_added?.cancel());
    unawaited(_opened?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.own) {
      return _ownView(context);
    }
    return FutureBuilder<PebbleProfile?>(
      future: _friend,
      builder: (BuildContext context, AsyncSnapshot<PebbleProfile?> snap) {
        final PebbleProfile? p = snap.data;
        if (p == null || p.isEmpty) {
          return ZenEmpty(
            key: const Key('pebbles-friend-empty'),
            icon: Icons.landscape_outlined,
            title: t('Brak kamyczków.'),
            text: t(
              'Ta osoba nie pokazała jeszcze kamyczków albo nie jesteście '
              'znajomymi.',
            ),
          );
        }
        return Column(
          key: const Key('pebbles-friend'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (p.created.isNotEmpty) ...<Widget>[
              ZenSection(t('Stworzone'), top: 8),
              _Grid(
                items: <_Item>[
                  for (final PebbleProfileItem i in p.created) _Item(i.card),
                ],
              ),
            ],
            if (p.collected.isNotEmpty) ...<Widget>[
              ZenSection(t('Zebrane')),
              _Grid(
                items: <_Item>[
                  for (final PebbleProfileItem i in p.collected)
                    _Item(i.card, foundAt: i.foundAtMillis, note: i.findNote),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _ownView(BuildContext context) {
    final PebbleStore? store = _store;
    final ZenColors zen = ZenColors.of(context);
    if (store == null) {
      return ZenEmpty(
        icon: Icons.sync_rounded,
        title: t('Kamyczki jeszcze się wczytują…'),
      );
    }
    final List<PebbleEntry> created = store.created;
    final List<PebbleEntry> collected = store.collected;
    final List<PebbleKeepRequest> requests = store.keepRequests;
    final PebbleService? service = ref.watch(pebbleServiceProvider);
    final SocialHubState social = ref.watch(socialHubControllerProvider);
    return Column(
      key: const Key('pebbles-own'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 8,
          children: <Widget>[
            FilledButton.icon(
              key: const Key('pebble-create'),
              onPressed: () => unawaited(startPebbleCreation(context, ref)),
              icon: const Icon(Icons.brush_outlined),
              label: Text(t('Stwórz kamyczek')),
            ),
            OutlinedButton.icon(
              key: const Key('pebble-scan'),
              onPressed: () => unawaited(scanPebble(context, ref)),
              icon: const Icon(Icons.qr_code_scanner_rounded),
              label: Text(t('Skanuj kamyczek')),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          t('Twoje kamyczki widzą tylko Twoi znajomi.'),
          style: TextStyle(color: zen.textMuted, fontSize: 12.5),
        ),
        for (final PebbleKeepRequest r in requests)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ZenCard(
              key: Key('pebble-keep-request-${r.card.id.text}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      StoredPebbleView(card: r.card, size: 56),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          pebbleKeepQuestion(switch (social.friendByAddress(
                            r.from,
                          )) {
                            final f? => social.nameFor(f),
                            null => r.card.authorName,
                          }, r),
                          style: TextStyle(color: zen.textPrimary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        key: Key('pebble-keep-no-${r.card.id.text}'),
                        onPressed: () =>
                            unawaited(service?.hosting.declineKeep(r.card.id)),
                        child: Text(t('Nie')),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        key: Key('pebble-keep-yes-${r.card.id.text}'),
                        onPressed: () =>
                            unawaited(service?.hosting.acceptKeep(r.card.id)),
                        child: Text(t('Zgadzam się')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ZenSection(t('Stworzone')),
        if (created.isEmpty)
          Text(
            t(
              'Pomaluj swój pierwszy kamyczek i zostaw jego kod w ciekawym '
              'miejscu.',
            ),
            style: TextStyle(color: zen.textSecondary, fontSize: 14),
          )
        else
          _Grid(
            items: <_Item>[for (final PebbleEntry e in created) _Item(e.card)],
          ),
        ZenSection(t('Zebrane')),
        if (collected.isEmpty)
          Text(
            t('Znalazłeś(-aś) naklejkę z kamyczkiem? Zeskanuj jej kod.'),
            style: TextStyle(color: zen.textSecondary, fontSize: 14),
          )
        else
          _Grid(
            items: <_Item>[
              for (final PebbleEntry e in collected)
                _Item(e.card, foundAt: e.foundAtMillis, note: e.findNote),
            ],
          ),
        if (store.kept.any(
          (PebbleEntry e) => !e.created && !e.collected,
        )) ...<Widget>[
          ZenSection(t('Przechowujesz dla znajomych')),
          _Grid(
            items: <_Item>[
              for (final PebbleEntry e in store.kept)
                if (!e.created && !e.collected) _Item(e.card),
            ],
          ),
        ],
      ],
    );
  }
}

final class _Item {
  const _Item(this.card, {this.foundAt, this.note = ''});

  final PebbleCard card;
  final int? foundAt;
  final String note;
}

/// Stones in a grid; a tap opens one full screen.
class _Grid extends StatelessWidget {
  const _Grid({required this.items});

  final List<_Item> items;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        for (final _Item i in items)
          InkWell(
            key: Key('pebble-tile-${i.card.id.text}'),
            borderRadius: BorderRadius.circular(16),
            onTap: () => unawaited(
              PebbleDetailScreen.open(
                context,
                i.card,
                foundAtMillis: i.foundAt,
                findNote: i.note,
              ),
            ),
            child: SizedBox(
              width: 96,
              child: Column(
                children: <Widget>[
                  StoredPebbleView(card: i.card, size: 88),
                  const SizedBox(height: 4),
                  Text(
                    i.card.name.isEmpty ? t('Kamyczek') : i.card.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: zen.textPrimary, fontSize: 12.5),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// "Kamyczki" on its own screen (a request to keep a pebble opens it).
class PebblesScreen extends StatelessWidget {
  const PebblesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const PebblesScreen(),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('pebbles-screen'),
    appBar: ZenSectionBar(title: t('Kamyczki')),
    body: SafeArea(
      top: false,
      child: ListView(
        padding: readableInsets(context, bottom: 32),
        children: const <Widget>[
          PebbleProfileSection(account: null, own: true),
        ],
      ),
    ),
  );
}

/// "Udostępniaj zebrane kamyczki" (Ustawienia → Sieć i usługa).
class PebbleServeSwitch extends ConsumerWidget {
  const PebbleServeSwitch({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    return SwitchListTile.adaptive(
      key: const Key('settings-serve-pebbles-switch'),
      contentPadding: EdgeInsets.zero,
      value: ref.watch(
        appSettingsControllerProvider.select((AppSettings s) => s.servePebbles),
      ),
      onChanged: (bool value) => unawaited(
        ref.read(appSettingsControllerProvider.notifier).setServePebbles(value),
      ),
      title: Text(
        t('Udostępniaj zebrane kamyczki'),
        style: TextStyle(
          color: zen.textPrimary,
          fontSize: 15.5,
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        t(
          'Kto szuka kamyczka, który zebrałeś(-aś), dostanie od Ciebie jego '
          'wygląd, gdy autor i opiekunowie są poza siecią.',
        ),
        style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
      ),
    );
  }
}

/// A small pebble, drawn from its whole painting where this device keeps
/// it (made here, or collected with its design), else from the card's
/// 16 x 16 preview (all a QR code carries).
class StoredPebbleView extends ConsumerStatefulWidget {
  const StoredPebbleView({required this.card, required this.size, super.key});

  final PebbleCard card;
  final double size;

  @override
  ConsumerState<StoredPebbleView> createState() => _StoredPebbleViewState();
}

class _StoredPebbleViewState extends ConsumerState<StoredPebbleView> {
  Uint8List? _design;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final PebbleStore? store = ref.read(pebbleServiceProvider)?.store;
    if (store == null || !(store.entry(widget.card.id)?.hasDesign ?? false)) {
      return;
    }
    final Uint8List? design = await store.design(widget.card.id);
    if (mounted && design != null) {
      setState(() => _design = design);
    }
  }

  @override
  Widget build(BuildContext context) => PebbleView(
    key: ValueKey<bool>(_design != null),
    design: _design,
    card: widget.card,
    size: widget.size,
  );
}
