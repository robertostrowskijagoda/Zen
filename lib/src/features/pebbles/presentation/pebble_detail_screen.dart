import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart'
    show readableInsets;
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_link.dart';
import 'package:zen/src/features/pebbles/pebble_parts.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_code_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// One pebble full screen: the stone to turn, its name, note, author and
/// date; for a collected one when and where it was found (the finder's own
/// note); for one of this account's the keepers, the finders, the sticker,
/// the link; for one kept for its author, giving the role up.
class PebbleDetailScreen extends ConsumerStatefulWidget {
  const PebbleDetailScreen({
    required this.card,
    this.foundAtMillis,
    this.findNote = '',
    this.justPublished = false,
    super.key,
  });

  final PebbleCard card;

  /// When and where it was found, for a friend's collected pebble (one in
  /// this device's store says it itself).
  final int? foundAtMillis;
  final String findNote;

  /// Opened right after publishing: the sticker is offered first.
  final bool justPublished;

  static Future<void> open(
    BuildContext context,
    PebbleCard card, {
    int? foundAtMillis,
    String findNote = '',
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => PebbleDetailScreen(
        card: card,
        foundAtMillis: foundAtMillis,
        findNote: findNote,
      ),
    ),
  );

  @override
  ConsumerState<PebbleDetailScreen> createState() => _PebbleDetailScreenState();
}

class _PebbleDetailScreenState extends ConsumerState<PebbleDetailScreen> {
  PebbleStore? _store;
  Uint8List? _design;
  bool _designAsked = false;
  late final TextEditingController _note = TextEditingController();
  bool _noteFilled = false;

  /// The keepers the author picked for the QR code ("Przechowujący w kodzie
  /// QR"); `null` until they change it: the first who agreed then.
  Set<String>? _codeKeepers;

  /// The keepers this pebble's QR code names (pebble_link.dart): on one's
  /// own pebble those picked (else the first who agreed), on a collected
  /// one the keepers it is known to have; [kPebbleQrKeepersMax] at most.
  List<String> _keepersInCode(PebbleService? service, PebbleEntry? entry) {
    if (service == null || entry == null) {
      return const <String>[];
    }
    if (!entry.created) {
      return <String>[
        ...?entry.keepers?.keepers,
        if (entry.keepers == null) ...entry.hinted,
      ].take(kPebbleQrKeepersMax).toList();
    }
    final List<String> agreed = <String>[
      for (final PebbleKeeperStatus k in service.store.keepersOf(entry.id))
        if (k.state == PebbleKeeperState.accepted) k.address,
    ];
    final Set<String>? picked = _codeKeepers;
    return (picked == null ? agreed : agreed.where(picked.contains))
        .take(kPebbleQrKeepersMax)
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _store = ref.read(pebbleServiceProvider)?.store;
    _store?.addListener(_changed);
    unawaited(_loadDesign());
  }

  @override
  void dispose() {
    _store?.removeListener(_changed);
    _note.dispose();
    super.dispose();
  }

  void _changed() {
    if (!mounted) {
      return;
    }
    setState(() {});
    if (_design == null) {
      unawaited(_loadDesign());
    }
  }

  Future<void> _loadDesign() async {
    final PebbleStore? store = _store;
    if (store == null || _designAsked) {
      return;
    }
    if (!(store.entry(widget.card.id)?.hasDesign ?? false)) {
      return;
    }
    _designAsked = true;
    final Uint8List? design = await store.design(widget.card.id);
    if (mounted) {
      setState(() => _design = design);
    }
  }

  Future<bool> _confirm(String title, String text, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          scrollable: true,
          title: Text(title),
          content: Text(text),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final PebbleService? service = ref.watch(pebbleServiceProvider);
    final PebbleEntry? entry = service?.store.entry(widget.card.id);
    // The store's card: the full one once it came with the design.
    final PebbleCard card = entry?.card ?? widget.card;
    final int? foundAt = entry?.foundAtMillis ?? widget.foundAtMillis;
    final String findNote = entry?.findNote ?? widget.findNote;
    if (!_noteFilled && entry != null && entry.collected) {
      _noteFilled = true;
      _note.text = entry.findNote;
    }
    final double size = (MediaQuery.sizeOf(context).width - 64).clamp(
      160.0,
      340.0,
    );
    return Scaffold(
      key: const Key('pebble-detail-screen'),
      appBar: ZenSectionBar(
        title: card.name.isEmpty ? t('Kamyczek') : card.name,
        actions: <Widget>[
          if (entry != null && (entry.created || entry.collected))
            IconButton(
              key: const Key('pebble-show-code'),
              tooltip: t('Pokaż kod'),
              icon: const Icon(Icons.qr_code_2_rounded),
              onPressed: () => unawaited(
                PebbleCodeScreen.open(
                  context,
                  card,
                  keepers: _keepersInCode(service, entry),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: readableInsets(context, bottom: 32),
          children: <Widget>[
            Center(
              child: PebbleView(
                key: const Key('pebble-detail-view'),
                design: _design,
                card: card,
                size: size,
                interactive: true,
              ),
            ),
            if (entry != null && !entry.hasDesign)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Center(
                  child: ZenPill(
                    key: const Key('pebble-detail-waiting'),
                    text: t('Pełny wygląd jeszcze w drodze'),
                    icon: Icons.downloading_rounded,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            if (card.note.isNotEmpty)
              Text(
                card.note,
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textPrimary, fontSize: 16),
              ),
            const SizedBox(height: 6),
            Text(
              pebbleByline(card),
              textAlign: TextAlign.center,
              style: TextStyle(color: zen.textMuted, fontSize: 13),
            ),
            if (entry != null && (entry.created || entry.collected))
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Center(
                  child: OutlinedButton.icon(
                    key: const Key('pebble-show-code-button'),
                    onPressed: () => unawaited(
                      PebbleCodeScreen.open(
                        context,
                        card,
                        keepers: _keepersInCode(service, entry),
                      ),
                    ),
                    icon: const Icon(Icons.qr_code_2_rounded),
                    label: Text(t('Pokaż kod')),
                  ),
                ),
              ),
            if (widget.justPublished && entry != null && entry.created)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: ZenInfo(
                  key: const Key('pebble-published-info'),
                  icon: Icons.celebration_outlined,
                  // Where it lives: only here until a friend keeps it.
                  text:
                      service != null &&
                          service.store.keepersOf(card.id).isEmpty
                      ? t(
                          'Kamyczek gotowy! Wydrukuj naklejkę z kodem QR i '
                          'zostaw ją w ciekawym miejscu. Na razie jest tylko '
                          'na Twoim telefonie: gdy telefon będzie wyłączony '
                          'albo poza siecią, nikt go nie pobierze. Zen sam '
                          'poprosi znajomych o przechowanie, gdy będą w '
                          'sieci. Kto się zgodził, zobaczysz niżej w '
                          '„Opiekunowie”, także później: Kamyczki → ten '
                          'kamyczek.',
                        )
                      : t(
                          'Kamyczek gotowy! Wydrukuj naklejkę z kodem QR i '
                          'zostaw ją w ciekawym miejscu. Zen poprosił '
                          'znajomych o przechowanie: dopóki żaden się nie '
                          'zgodzi, kamyczek jest dostępny tylko wtedy, gdy '
                          'Twój telefon jest w sieci. Odpowiedzi widać niżej '
                          'w „Opiekunowie”, także później: Kamyczki → ten '
                          'kamyczek.',
                        ),
                ),
              ),
            if (foundAt != null &&
                (entry == null || entry.collected)) ...<Widget>[
              ZenSection(t('Znaleziony')),
              Text(
                ZenFormat.date(DateTime.fromMillisecondsSinceEpoch(foundAt)),
                style: TextStyle(color: zen.textPrimary, fontSize: 15),
              ),
              if (entry == null && findNote.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    findNote,
                    style: TextStyle(color: zen.textSecondary, fontSize: 14),
                  ),
                ),
            ],
            if (entry != null && entry.collected) ...<Widget>[
              const SizedBox(height: 8),
              TextField(
                key: const Key('pebble-find-note'),
                controller: _note,
                maxLength: kPebbleFindNoteMaxChars,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Gdzie go znalazłeś(-aś)?'),
                  helperText: t('Widzą to Twoi znajomi.'),
                  prefixIcon: const Icon(Icons.place_outlined),
                  suffixIcon: IconButton(
                    key: const Key('pebble-find-note-save'),
                    tooltip: t('Zapisz'),
                    icon: const Icon(Icons.check_rounded),
                    onPressed: () {
                      FocusScope.of(context).unfocus();
                      unawaited(
                        service!.store.setFindNote(card.id, _note.text),
                      );
                    },
                  ),
                ),
              ),
            ],
            if (entry != null && entry.created && service != null)
              ..._ownPart(service, entry, zen),
            if (entry != null &&
                entry.kept &&
                !entry.created &&
                service != null)
              ..._keptPart(service, entry),
            if (entry != null &&
                entry.collected &&
                service != null) ...<Widget>[
              const SizedBox(height: 16),
              TextButton.icon(
                key: const Key('pebble-remove'),
                onPressed: () async {
                  if (!await _confirm(
                    t('Usunąć z kolekcji?'),
                    t(
                      'Kamyczek zniknie z Twojego profilu. Możesz go zebrać '
                      'ponownie, skanując jego kod.',
                    ),
                    t('Usuń'),
                  )) {
                    return;
                  }
                  await service.store.drop(card.id, PebbleRole.collected);
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
                icon: const Icon(Icons.delete_outline_rounded),
                label: Text(t('Usuń z kolekcji')),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _ownPart(
    PebbleService service,
    PebbleEntry entry,
    ZenColors zen,
  ) {
    final PebbleCard card = entry.card;
    final List<PebbleKeeperStatus> keepers = service.store.keepersOf(card.id);
    final SocialHubState social = ref.watch(socialHubControllerProvider);
    String nameOf(String address) {
      final f = social.friendByAddress(address);
      return f == null ? address : social.nameFor(f);
    }

    final int accepted = service.store.acceptedKeepers(card.id);
    final bool open = entry.madeHere && !entry.retired;
    // Whom "Losuj ponownie" could still ask, and whether it would change
    // anything: with every keeper agreed and the target reached it hides.
    final int fresh = open ? service.hosting.freshKeeperCandidates(card.id) : 0;
    final bool waiting = keepers.any(
      (PebbleKeeperStatus k) => k.state == PebbleKeeperState.asked,
    );
    final bool full = accepted >= service.hosting.keeperTarget;
    final bool noFriends = open && !service.hosting.hasFriends;
    final String? cannotDraw = !open || noFriends || full && !waiting
        ? null
        : fresh == 0
        ? t(
            'Nie ma kogo jeszcze poprosić: wszyscy Twoi znajomi już zostali '
            'poproszeni. Gdy dodasz kolejnych, Zen poprosi ich sam.',
          )
        : null;
    final List<String> agreed = <String>[
      for (final PebbleKeeperStatus k in keepers)
        if (k.state == PebbleKeeperState.accepted) k.address,
    ];
    final List<String> inCode = _keepersInCode(service, entry);
    return <Widget>[
      ZenSection(
        t('Przechowujący w kodzie QR'),
        key: const Key('pebble-code-keepers'),
      ),
      ZenInfo(
        icon: Icons.qr_code_2_rounded,
        text: agreed.isEmpty
            ? t(
                'Gdy znajomi zgodzą się przechować kamyczek, wpisz ich tu do '
                'kodu QR: znalazca zapyta ich o pełny wygląd, kiedy Twój '
                'telefon będzie wyłączony.',
              )
            : t(
                'Wybierz do {n} osób. Gdy Twój telefon będzie wyłączony, '
                'znalazca zapyta je o pełny wygląd kamyczka, nawet jeśli nie '
                'zna ani Ciebie, ani ich. Bez nich dotrze do niego tylko '
                'przez wspólnych znajomych. Wybór dotyczy naklejek i kodów, '
                'które pokażesz od teraz: wydrukowane wcześniej zostają bez '
                'zmian.',
                <String, Object?>{'n': kPebbleQrKeepersMax},
              ),
      ),
      if (agreed.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final String a in agreed)
                FilterChip(
                  key: Key('pebble-code-keeper-$a'),
                  label: Text(nameOf(a)),
                  selected: inCode.contains(a),
                  onSelected: (bool on) {
                    if (on && inCode.length >= kPebbleQrKeepersMax) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            t('Najwyżej {n} osoby w kodzie.', <String, Object?>{
                              'n': kPebbleQrKeepersMax,
                            }),
                          ),
                        ),
                      );
                      return;
                    }
                    setState(
                      () => _codeKeepers = <String>{
                        ...inCode.where((String k) => k != a),
                        if (on) a,
                      },
                    );
                  },
                ),
            ],
          ),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        key: const Key('pebble-print-sticker'),
        onPressed: () => unawaited(
          openPebbleSticker(
            context,
            link: pebbleWebLink(card, keepers: inCode),
            name: card.name,
            author: card.authorName,
          ),
        ),
        icon: const Icon(Icons.qr_code_2_rounded),
        label: Text(t('Wydrukuj naklejkę')),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        key: const Key('pebble-copy-link'),
        onPressed: () async {
          await copyPublicText(pebbleShareLink(card));
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t('Skopiowano link do kamyczka.'))),
            );
          }
        },
        icon: const Icon(Icons.link_rounded),
        label: Text(t('Kopiuj link')),
      ),
      ZenSection(
        t('Opiekunowie'),
        action: open && !noFriends && !(full && !waiting)
            ? t('Losuj ponownie')
            : null,
        onAction: fresh == 0 ? null : () => unawaited(_redraw(service, card)),
        key: const Key('pebble-keepers-section'),
      ),
      Text(
        entry.retired
            ? t('Kamyczek wycofany: opiekunowie już go nie udostępniają.')
            : noFriends && keepers.isEmpty
            ? t(
                'Nie masz jeszcze znajomych, którzy mogliby przechować '
                'kamyczek. Gdy dodasz znajomych, Zen poprosi ich sam.',
              )
            : tn(
                accepted,
                one: '{n} znajomy przechowuje ten kamyczek.',
                few: '{n} znajomych przechowuje ten kamyczek.',
                many: '{n} znajomych przechowuje ten kamyczek.',
              ),
        key: const Key('pebble-keepers-count'),
        style: TextStyle(color: zen.textSecondary, fontSize: 14),
      ),
      if (cannotDraw != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            cannotDraw,
            key: const Key('pebble-keepers-nobody-new'),
            style: TextStyle(color: zen.textMuted, fontSize: 13),
          ),
        ),
      for (final PebbleKeeperStatus k in keepers)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(switch (k.state) {
            PebbleKeeperState.accepted => Icons.verified_outlined,
            PebbleKeeperState.asked => Icons.hourglass_top_rounded,
            _ => Icons.remove_circle_outline_rounded,
          }),
          title: Text(nameOf(k.address)),
          subtitle: Text(switch (k.state) {
            PebbleKeeperState.accepted => t('przechowuje'),
            PebbleKeeperState.asked => t('czeka na odpowiedź'),
            PebbleKeeperState.declined => t('odmówił(a)'),
            PebbleKeeperState.resigned => t('zrezygnował(a)'),
            PebbleKeeperState.silent => t('nie odpowiedział(a)'),
          }),
        ),
      ZenSection(t('Znalazcy')),
      Text(
        tn(
          service.store.finderCount(card.id),
          one: '{n} osoba dała znać, że go znalazła.',
          few: '{n} osoby dały znać, że go znalazły.',
          many: '{n} osób dało znać, że go znalazło.',
        ),
        key: const Key('pebble-finders-count'),
        style: TextStyle(color: zen.textSecondary, fontSize: 14),
      ),
      if (entry.madeHere && !entry.retired) ...<Widget>[
        const SizedBox(height: 16),
        TextButton.icon(
          key: const Key('pebble-retire'),
          onPressed: () async {
            if (!await _confirm(
              t('Wycofać kamyczek?'),
              t(
                'Opiekunowie przestaną go udostępniać. Kto już go zebrał, '
                'zachowa swoją kopię.',
              ),
              t('Wycofaj'),
            )) {
              return;
            }
            final bool done = await service.hosting.retire(card.id);
            if (!done && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    t(
                      'Klucz konta jest zablokowany. Odblokuj go i spróbuj '
                      'ponownie.',
                    ),
                  ),
                ),
              );
            }
          },
          icon: const Icon(Icons.undo_rounded),
          label: Text(t('Wycofaj kamyczek')),
        ),
      ],
    ];
  }

  /// "Losuj ponownie": says what came of it, so the press is never silent.
  Future<void> _redraw(PebbleService service, PebbleCard card) async {
    final int asked = await service.hosting.redraw(card.id);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          asked == 0
              ? t(
                  'Nie ma kogo jeszcze poprosić: wszyscy Twoi znajomi już '
                  'zostali poproszeni. Gdy dodasz kolejnych, Zen poprosi ich '
                  'sam.',
                )
              : tn(
                  asked,
                  one: 'Poproszono {n} znajomego o przechowanie kamyczka.',
                  few: 'Poproszono {n} znajomych o przechowanie kamyczka.',
                  many: 'Poproszono {n} znajomych o przechowanie kamyczka.',
                ),
        ),
      ),
    );
  }

  List<Widget> _keptPart(PebbleService service, PebbleEntry entry) => <Widget>[
    const SizedBox(height: 16),
    ZenInfo(
      icon: Icons.inventory_2_outlined,
      text: t(
        'Przechowujesz ten kamyczek dla autora: inni dostają od Ciebie jego '
        'wygląd, gdy autor jest poza siecią.',
      ),
    ),
    const SizedBox(height: 8),
    TextButton.icon(
      key: const Key('pebble-resign'),
      onPressed: () async {
        if (!await _confirm(
          t('Przestać przechowywać?'),
          t('Autor poprosi kogoś innego.'),
          t('Przestań'),
        )) {
          return;
        }
        await service.hosting.resign(entry.id);
        if (mounted) {
          Navigator.of(context).pop();
        }
      },
      icon: const Icon(Icons.logout_rounded),
      label: Text(t('Przestań przechowywać')),
    ),
  ];
}

/// "{author} · {date}" under a pebble; only the author while the date is
/// not known yet (a pebble collected from its QR card, before its full
/// card came).
String pebbleByline(PebbleCard card) {
  final String author = card.authorName.isEmpty
      ? t('Autor nieznany')
      : card.authorName;
  final DateTime? created = card.created;
  return created == null
      ? author
      : t('{author} · {date}', <String, Object?>{
          'author': author,
          'date': ZenFormat.date(created),
        });
}
