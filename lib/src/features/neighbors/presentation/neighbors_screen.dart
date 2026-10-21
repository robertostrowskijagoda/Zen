import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart'
    show pickImageBytes;
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/safe_photo.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/neighbors/presentation/flat_door_screen.dart';
import 'package:zen/src/features/neighbors/presentation/neighbor_screen.dart';
import 'package:zen/src/features/social/peer_qr_scanner.dart';

/// The tone of the neighbours screens.
Color neighborsTone(ZenColors zen) => zenTone(zen, 5);

/// The icon of an invitation, an offer or a need.
IconData flatItemIcon(FlatItemKind kind) => switch (kind) {
  FlatItemKind.invite => Icons.celebration_rounded,
  FlatItemKind.offer => Icons.volunteer_activism_rounded,
  FlatItemKind.need => Icons.pan_tool_rounded,
};

/// The colour of an invitation, an offer or a need.
Color flatItemTone(ZenColors zen, FlatItemKind kind) => switch (kind) {
  FlatItemKind.invite => neighborsTone(zen),
  FlatItemKind.offer => zen.success,
  FlatItemKind.need => zen.warning,
};

/// A flat's photo (or its icon when there is none), [size] square.
class FlatAvatar extends StatelessWidget {
  const FlatAvatar({
    required this.profile,
    this.size = 52,
    this.icon = Icons.home_rounded,
    super.key,
  });

  final FlatProfile profile;
  final double size;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (profile.photo.isEmpty) {
      return ZenIconBadge(icon: icon, tone: neighborsTone(zen), size: size);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        ZenLook.of(context).radius(size * 0.3),
      ),
      child: SizedBox(
        width: size,
        height: size,
        // Re-encoded before showing: it may come from another flat.
        child: SafePhoto(data: profile.photo, clean: true, icon: icon),
      ),
    );
  }
}

/// What a flat's card shows besides its name ([FlatDoorView]): its note,
/// the residents' first names, "O nas" and its invitations and offers, as
/// far as that household shows them before "Wpuść".
class FlatCardDetails extends StatelessWidget {
  const FlatCardDetails({required this.card, super.key});

  final FlatCard card;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final FlatProfile p = card.profile;
    Widget row(IconData icon, String text) => Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: zen.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 13.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
    final List<Widget> rows = <Widget>[
      if (card.note.isNotEmpty) row(Icons.sticky_note_2_outlined, card.note),
      if (card.names.isNotEmpty)
        row(
          Icons.people_alt_rounded,
          t('Domownicy: {names}', {'names': card.names.join(', ')}),
        ),
      if (p.about.isNotEmpty) row(Icons.info_outline_rounded, p.about),
      for (final FlatItem i in p.items.take(6))
        row(flatItemIcon(i.kind), i.text),
    ];
    if (rows.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: rows,
    );
  }
}

/// A card for an invitation, an offer or a need: icon, text, a line under
/// it, actions on the right and optionally a row of buttons below.
class FlatItemCard extends StatelessWidget {
  const FlatItemCard({
    required this.kind,
    required this.text,
    this.meta,
    this.trailing = const <Widget>[],
    this.below,
    super.key,
  });

  final FlatItemKind kind;
  final String text;
  final String? meta;
  final List<Widget> trailing;
  final Widget? below;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = flatItemTone(zen, kind);
    return ZenCard(
      padding: EdgeInsets.fromLTRB(14, 12, trailing.isEmpty ? 14 : 4, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenIconBadge(icon: flatItemIcon(kind), tone: tone, size: 40),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      text,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    if (meta != null && meta!.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        meta!,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              ...trailing,
            ],
          ),
          if (below != null) ...<Widget>[const SizedBox(height: 10), below!],
        ],
      ),
    );
  }
}

/// Short date and hour: "12.10 19:00".
String flatDate(int millis) {
  return ZenFormat.dayMonthTime(DateTime.fromMillisecondsSinceEpoch(millis));
}

/// Scans a QR (camera) or, where there is no camera, takes the code pasted.
Future<String?> scanOrPaste(
  BuildContext context,
  WidgetRef ref, {
  required String title,
}) async {
  final PeerQrScanner scanner = ref.read(peerQrScannerProvider);
  if (scanner.isSupported) {
    return scanner.scan(context);
  }
  final TextEditingController c = TextEditingController();
  final String? text = await showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 400,
        child: TextField(
          key: const Key('flat-paste'),
          controller: c,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          decoration: InputDecoration(
            labelText: t('Wklej kod (zen-flat:… lub zen-home:…)'),
            prefixIcon: const Icon(Icons.content_paste_rounded),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(c.text.trim()),
          child: Text(t('Dalej')),
        ),
      ],
    ),
  );
  disposeLater(c);
  return text == null || text.isEmpty ? null : text;
}

/// Knocks on the door [code] and tells how it went. With [ask] it
/// asks first: a door link can come from any page or app, and a knock
/// sends this flat's profile.
Future<void> knockOnFlatDoor(
  BuildContext context,
  NeighborsService service,
  FlatDoorCode code, {
  bool ask = false,
}) async {
  if (ask && service.hasFlat && code.key != service.profile?.key) {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(
          t('Zapukać do „{name}”?', <String, Object?>{'name': code.name}),
        ),
        content: Text(
          t(
            'Zobaczą Waszą wizytówkę. Profilami wymienicie się, gdy Was '
            'wpuszczą.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('flat-knock-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Zapukaj')),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) {
      return;
    }
  }
  final FlatScan r = await service.scanDoor(code);
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(switch (r) {
        FlatScan.sent => t(
          'Pukamy do „{name}”… Profil pojawi się, gdy ich telefon odpowie.',
          <String, Object?>{'name': code.name},
        ),
        FlatScan.own => t('To Wasz własny kod.'),
        FlatScan.noFlat => t('Najpierw załóż profil mieszkania.'),
        FlatScan.alreadyNeighbor => t('„{name}” już są na liście.', {
          'name': code.name,
        }),
        FlatScan.expired => t(
          'To zaproszenie już wygasło. Zeskanujcie kod z ich drzwi.',
        ),
      }),
    ),
  );
}

/// "Sąsiedzi": this flat, its door QR, "Moi sąsiedzi" and
/// invitations heard nearby.
class NeighborsScreen extends ConsumerWidget {
  const NeighborsScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const NeighborsScreen(),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NeighborsService service = ref.watch(neighborsServiceProvider);
    return Scaffold(
      key: const Key('neighbors-screen'),
      appBar: ZenSectionBar(title: t('Sąsiedzi')),
      body: SelectionArea(
        child: ListenableBuilder(
          listenable: service,
          builder: (BuildContext context, Widget? _) {
            if (service.joining && !service.hasFlat) {
              return _Joining(service: service);
            }
            if (!service.hasFlat) {
              return _NoFlat(service: service);
            }
            return _FlatHome(service: service);
          },
        ),
      ),
    );
  }
}

class _Joining extends StatelessWidget {
  const _Joining({required this.service});

  final NeighborsService service;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = neighborsTone(zen);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 84,
              height: 84,
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: tone.withValues(alpha: 0.14),
              ),
              child: CircularProgressIndicator(color: tone, strokeWidth: 3),
            ),
            const SizedBox(height: 18),
            Text(
              t('Czekam, aż domownik potwierdzi…'),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t(
                'Na telefonie, który pokazał kod, pojawi się prośba: '
                '„Dołącz” albo „Odrzuć”.',
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => unawaited(service.leaveFlat()),
              child: Text(t('Anuluj')),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoFlat extends ConsumerStatefulWidget {
  const _NoFlat({required this.service});

  final NeighborsService service;

  @override
  ConsumerState<_NoFlat> createState() => _NoFlatState();
}

class _NoFlatState extends ConsumerState<_NoFlat> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _place = TextEditingController();
  final TextEditingController _about = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _place.dispose();
    _about.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('Wpisz, kim jesteście.'))));
      return;
    }
    final FlatProfile? p = await widget.service.createFlat(
      _name.text,
      place: _place.text,
      about: _about.text,
    );
    if (p == null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Najpierw połącz się z siecią.'))),
      );
    }
  }

  Future<void> _join() async {
    final String? text = await scanOrPaste(
      context,
      ref,
      title: t('Kod domownika'),
    );
    if (text == null || !mounted) {
      return;
    }
    final FlatHomeCode? code = FlatHomeCode.parse(text);
    if (code == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('To nie jest kod domownika.'))));
      return;
    }
    if (!await widget.service.joinFlat(code) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Ten kod już wygasł — poproś o nowy.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = neighborsTone(zen);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenHero(
          title: t('Wasze mieszkanie'),
          icon: Icons.home_rounded,
          tone: tone,
          text: t(
            'Profil sąsiedzki należy do Was — rodziny, pary, '
            'współlokatorów — w mieszkaniu, w którym teraz mieszkacie: '
            '„Nowakowie · m. 12”. Zapraszacie na kawę czy grilla, '
            'oferujecie pomoc, piszecie do siebie.',
          ),
        ),
        ZenInfo(
          icon: Icons.lock_rounded,
          tone: tone,
          title: t('Konta zostają prywatne'),
          text: t(
            'Sąsiedzi nie widzą Waszych kont, dopóki sami się nie '
            'poznacie. Gdy się wyprowadzicie, nowi lokatorzy założą własny '
            'profil od zera.',
          ),
        ),
        ZenSection(t('Załóż profil')),
        TextField(
          key: const Key('flat-name'),
          controller: _name,
          maxLength: 60,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: t('Kim jesteście?'),
            hintText: t('Nowakowie / Ania i Tomek'),
            prefixIcon: const Icon(Icons.family_restroom_rounded),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          key: const Key('flat-place'),
          controller: _place,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: t('Gdzie mieszkacie? (nie trzeba)'),
            hintText: t('m. 12, 3 piętro'),
            prefixIcon: const Icon(Icons.apartment_rounded),
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          key: const Key('flat-about'),
          controller: _about,
          minLines: 2,
          maxLines: 3,
          maxLength: 1000,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: t('O nas (nie trzeba)'),
            hintText: t('Mamy małe dziecko, prosimy o ciszę po 20…'),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('flat-create'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => unawaited(_create()),
          icon: const Icon(Icons.home_rounded),
          label: Text(t('Załóż profil')),
        ),
        ZenSection(t('Albo dołącz'), top: 28),
        ZenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ZenIconBadge(icon: Icons.qr_code_scanner_rounded, tone: tone),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t('Ktoś z domowników już go założył?'),
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          t(
                            'Zeskanuj kod z jego telefonu (Domownicy → Pokaż '
                            'kod).',
                          ),
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13.5,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              OutlinedButton.icon(
                key: const Key('flat-join'),
                onPressed: () => unawaited(_join()),
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: Text(t('Dołącz — zeskanuj kod')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A square shortcut under the flat's card: icon over a short label.
class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final ShapeBorder shape = look.panelShape(zen, radius: 20);
    return Material(
      color: look.panelColor(zen),
      shape: shape,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 14, 6, 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              ZenIconBadge(icon: icon, tone: tone, size: 40),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FlatHome extends ConsumerWidget {
  const _FlatHome({required this.service});

  final NeighborsService service;

  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final String? text = await scanOrPaste(
      context,
      ref,
      title: t('Kod z drzwi'),
    );
    if (text == null || !context.mounted) {
      return;
    }
    final FlatDoorCode? code = FlatDoorCode.parse(text);
    if (code == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('To nie jest kod mieszkania.'))));
      return;
    }
    await _knock(context, code);
  }

  Future<void> _knock(BuildContext context, FlatDoorCode code) =>
      knockOnFlatDoor(context, service, code);

  Future<void> _edit(BuildContext context) async {
    final FlatProfile p = service.profile!;
    final TextEditingController name = TextEditingController(text: p.name);
    final TextEditingController place = TextEditingController(text: p.place);
    final TextEditingController about = TextEditingController(text: p.about);
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Nasz profil sąsiedzki')),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextField(
                  controller: name,
                  maxLength: 60,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: t('Kim jesteście?'),
                    prefixIcon: const Icon(Icons.family_restroom_rounded),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: place,
                  maxLength: 80,
                  decoration: InputDecoration(
                    labelText: t('Gdzie (np. m. 12)'),
                    prefixIcon: const Icon(Icons.apartment_rounded),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: about,
                  minLines: 2,
                  maxLines: 4,
                  maxLength: 1000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(labelText: t('O nas')),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.editProfile(
        name: name.text,
        place: place.text,
        about: about.text,
      );
    }
    disposeLater(name);
    disposeLater(place);
    disposeLater(about);
  }

  Future<void> _photo(BuildContext context) async {
    final bool has = service.profile?.photo.isNotEmpty ?? false;
    final String? action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              key: const Key('flat-photo-pick'),
              leading: const Icon(Icons.photo_library_rounded),
              title: Text(has ? t('Zmień zdjęcie') : t('Dodaj zdjęcie')),
              subtitle: Text(t('Zobaczą je sąsiedzi (małe, bez danych GPS).')),
              onTap: () => Navigator.of(sheet).pop('pick'),
            ),
            if (has)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded),
                title: Text(t('Usuń zdjęcie')),
                onTap: () => Navigator.of(sheet).pop('remove'),
              ),
          ],
        ),
      ),
    );
    if (action == 'remove') {
      await service.setPhoto(null);
      return;
    }
    if (action != 'pick') {
      return;
    }
    final List<Uint8List> picked;
    try {
      picked = await pickImageBytes();
    } on Object {
      return;
    }
    if (picked.isEmpty) {
      return;
    }
    final Uint8List? jpeg = await compute(compressFlatPhoto, picked.first);
    final bool ok = jpeg != null && await service.setPhoto(jpeg);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Tego zdjęcia nie da się użyć (format?).'))),
      );
    }
  }

  Future<void> _waveNearby(
    BuildContext context,
    WidgetRef ref,
    FlatItem item,
  ) async {
    final NearbyService nearby = ref.read(nearbyServiceProvider);
    // A code of its own, valid a day: never the sticker's permanent one.
    final Map<String, dynamic>? wave = await service.nearbyWave(item.id);
    if (wave == null) {
      return;
    }
    // Looks around for a moment when nothing scans yet, and stops again
    // after sending (a scan left on drains the battery).
    final int sent = await nearby.waveAround(
      wave,
      listen: const Duration(seconds: 4),
    );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            sent == 0
                ? t('Nikogo z Zen nie ma teraz w zasięgu Bluetooth.')
                : tn(
                    sent,
                    one: 'Wysłane do {n} telefonu w pobliżu.',
                    few: 'Wysłane do {n} telefonów w pobliżu.',
                    many: 'Wysłane do {n} telefonów w pobliżu.',
                  ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final FlatProfile p = service.profile!;
    final ZenColors zen = ZenColors.of(context);
    final Color tone = neighborsTone(zen);
    final List<NeighborFlat> neighbors = service.neighbors;
    final List<NearbyFlatInvite> near = service.nearbyInvites;
    final List<FlatKnock> knocks = service.knocks;
    final int members = p.members.length;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenCard(
          key: const Key('flat-header'),
          tone: tone,
          onTap: () => unawaited(_edit(context)),
          padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Tooltip(
                    message: t('Zdjęcie mieszkania'),
                    child: InkWell(
                      key: const Key('flat-photo'),
                      borderRadius: BorderRadius.circular(
                        ZenLook.of(context).radius(16),
                      ),
                      onTap: () => unawaited(_photo(context)),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          FlatAvatar(profile: p),
                          Positioned(
                            right: -4,
                            bottom: -4,
                            child: Container(
                              padding: const EdgeInsets.all(3),
                              decoration: BoxDecoration(
                                color: zen.surface,
                                shape: BoxShape.circle,
                                border: Border.all(color: zen.outlineSoft),
                              ),
                              child: Icon(
                                Icons.photo_camera_rounded,
                                size: 13,
                                color: zen.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          p.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 22,
                            weight: FontWeight.w600,
                          ),
                        ),
                        if (p.place.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 4),
                          Row(
                            children: <Widget>[
                              Icon(Icons.place_rounded, size: 15, color: tone),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  p.place,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: zen.textSecondary,
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(Icons.edit_rounded, color: zen.textMuted, size: 20),
                ],
              ),
              if (p.about.isNotEmpty) ...<Widget>[
                const SizedBox(height: 10),
                Text(
                  p.about,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  ZenPill(
                    text: tn(
                      members,
                      one: '{n} telefon domowników',
                      few: '{n} telefony domowników',
                      many: '{n} telefonów domowników',
                    ),
                    tone: tone,
                    icon: Icons.phone_android_rounded,
                  ),
                  ZenPill(
                    text: t('Sąsiedzi: {count}', {'count': neighbors.length}),
                    tone: tone,
                    icon: Icons.door_front_door_rounded,
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: _QuickAction(
                  key: const Key('flat-door'),
                  icon: Icons.qr_code_2_rounded,
                  label: t('Kod na drzwi'),
                  tone: tone,
                  onTap: () => unawaited(FlatDoorScreen.open(context)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickAction(
                  key: const Key('flat-scan'),
                  icon: Icons.qr_code_scanner_rounded,
                  label: t('Zeskanuj drzwi'),
                  tone: zenTone(zen, 6),
                  onTap: () => unawaited(_scan(context, ref)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _QuickAction(
                  key: const Key('flat-home'),
                  icon: Icons.family_restroom_rounded,
                  label: t('Domownicy'),
                  tone: zenTone(zen, 3),
                  onTap: () => unawaited(FlatHomeScreen.open(context)),
                ),
              ),
            ],
          ),
        ),
        // Phones asking to become residents (with a code this phone showed).
        for (final FlatJoinRequest r in service.joinRequests)
          FlatJoinRequestCard(service: service, request: r),
        if (knocks.isNotEmpty) ...<Widget>[
          ZenSection(t('Pukają do drzwi')),
          for (final FlatKnock k in knocks)
            ZenCard(
              key: Key('flat-knock-${k.profile.label}'),
              tone: tone,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      if (k.profile.photo.isNotEmpty)
                        FlatAvatar(profile: k.profile, size: 40)
                      else
                        ZenIconBadge(
                          icon: Icons.doorbell_rounded,
                          tone: tone,
                          size: 40,
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _TwoLines(
                          title: t('{name} puka do drzwi', {
                            'name': k.profile.label,
                          }),
                          subtitle: t(
                            'Dopiero gdy ich wpuścisz, wymienicie się profilami.',
                          ),
                          maxSubtitleLines: 3,
                        ),
                      ),
                    ],
                  ),
                  // What they chose to show before being let in.
                  FlatCardDetails(card: k.card),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      TextButton(
                        key: Key('flat-knock-reject-${k.profile.label}'),
                        onPressed: () => unawaited(service.rejectKnock(k.key)),
                        child: Text(t('Odmów')),
                      ),
                      FilledButton.tonalIcon(
                        key: Key('flat-knock-accept-${k.profile.label}'),
                        onPressed: () => unawaited(() async {
                          final bool done = await service.acceptKnock(k.key);
                          if (!done && context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(t('To pukanie już wygasło.')),
                              ),
                            );
                          }
                        }()),
                        icon: const Icon(
                          Icons.door_front_door_rounded,
                          size: 18,
                        ),
                        label: Text(t('Wpuść')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
        if (near.isNotEmpty) ...<Widget>[
          ZenSection(t('Zaproszenia w pobliżu')),
          for (final NearbyFlatInvite i in near)
            ZenCard(
              tone: tone,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      ZenIconBadge(
                        icon: Icons.bluetooth_rounded,
                        tone: tone,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              i.text,
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                height: 1.3,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              t('Usłyszane {date}', {'date': flatDate(i.at)}),
                              style: TextStyle(
                                color: zen.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => unawaited(service.dismissNearby(i)),
                        child: Text(t('Odrzuć')),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () => unawaited(() async {
                          await _knock(context, i.door);
                          await service.dismissNearby(i);
                        }()),
                        icon: const Icon(
                          Icons.person_add_alt_1_rounded,
                          size: 18,
                        ),
                        label: Text(t('Dodaj do sąsiadów')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
        _OwnItems(
          service: service,
          onWave: (FlatItem i) => unawaited(_waveNearby(context, ref, i)),
        ),
        ZenSection(t('Moi sąsiedzi')),
        if (neighbors.isEmpty && service.pending.isEmpty)
          ZenEmpty(
            icon: Icons.door_front_door_rounded,
            tone: tone,
            title: t('Jeszcze nikogo'),
            text: t('Powieś kod na drzwiach albo zeskanuj kod sąsiada.'),
          ),
        for (final FlatDoorCode c in service.pending.values)
          Builder(
            builder: (BuildContext context) {
              // Their card, when the household shows knockers one.
              final FlatCard? card = service.doorCard(c.key);
              return ZenCard(
                key: Key('flat-pending-${c.name}'),
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (card != null && card.profile.photo.isNotEmpty)
                          FlatAvatar(profile: card.profile, size: 40)
                        else
                          SizedBox(
                            width: 40,
                            height: 40,
                            child: Center(
                              child: SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: tone,
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _TwoLines(
                            title: card?.profile.label ?? c.name,
                            subtitle: t('Czekam, aż domownicy otworzą…'),
                          ),
                        ),
                      ],
                    ),
                    if (card != null) FlatCardDetails(card: card),
                  ],
                ),
              );
            },
          ),
        for (final MapEntry<String, String> s in service.staleDoors.entries)
          ZenCard(
            tone: zen.warning,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              children: <Widget>[
                ZenIconBadge(
                  icon: Icons.link_off_rounded,
                  tone: zen.warning,
                  size: 40,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _TwoLines(
                    title: s.value,
                    subtitle: t(
                      'Ten kod jest już nieważny — wygenerowali nowy.',
                    ),
                  ),
                ),
              ],
            ),
          ),
        for (final NeighborFlat f in neighbors)
          ZenCard(
            key: Key('flat-neighbor-${f.profile.label}'),
            onTap: () => unawaited(NeighborScreen.open(context, f.key)),
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (f.profile.photo.isNotEmpty)
                      FlatAvatar(profile: f.profile, size: 40)
                    else
                      ZenIconBadge(
                        icon: Icons.door_front_door_rounded,
                        tone: f.following ? tone : zen.textMuted,
                      ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _TwoLines(
                        title: f.profile.label,
                        subtitle: _neighborLine(f),
                        maxSubtitleLines: 3,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (f.weScanned && service.unread(f.key) > 0)
                      ZenPill(
                        text: '${service.unread(f.key)}',
                        tone: tone,
                        filled: true,
                      )
                    else if (f.weScanned)
                      Icon(Icons.chevron_right_rounded, color: zen.textMuted),
                  ],
                ),
                if (service.keyRival(f.key) != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ZenPill(
                      text: t('Dwa różne nowe klucze — sprawdź'),
                      tone: zen.warning,
                      icon: Icons.warning_amber_rounded,
                    ),
                  ),
                ],
                if (!f.weScanned) ...<Widget>[
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      key: Key('flat-confirm-${f.profile.label}'),
                      onPressed: () =>
                          unawaited(service.confirmNeighbor(f.key)),
                      icon: const Icon(
                        Icons.person_add_alt_1_rounded,
                        size: 18,
                      ),
                      label: Text(t('Dodaj')),
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  static String _neighborLine(NeighborFlat f) {
    final int invites = f.profile.of(FlatItemKind.invite).length;
    final int offers = f.profile.of(FlatItemKind.offer).length;
    final List<String> parts = <String>[
      if (invites > 0) t('zaproszenia: {count}', {'count': invites}),
      if (offers > 0) t('oferty: {count}', {'count': offers}),
      if (!f.weScanned)
        t('zeskanowali Wasz kod — dodaj, żeby dostawali Wasze zaproszenia'),
      if (!f.following) t('wyciszeni'),
    ];
    return parts.isEmpty ? t('sąsiedzi') : parts.join(' · ');
  }
}

/// A bold line and a softer one under it.
class _TwoLines extends StatelessWidget {
  const _TwoLines({
    required this.title,
    required this.subtitle,
    this.maxSubtitleLines = 2,
  });

  final String title;
  final String subtitle;
  final int maxSubtitleLines;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: zen.textPrimary,
            fontSize: 15.5,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          maxLines: maxSubtitleLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: zen.textSecondary,
            fontSize: 13.5,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}

class _OwnItems extends StatelessWidget {
  const _OwnItems({required this.service, required this.onWave});

  final NeighborsService service;
  final void Function(FlatItem item) onWave;

  @override
  Widget build(BuildContext context) {
    final FlatProfile p = service.profile!;
    final ZenColors zen = ZenColors.of(context);
    Widget section(FlatItemKind kind, String title, String empty) {
      final List<FlatItem> items = p.of(kind).toList();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 20, 0, 6),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    title.toUpperCase(),
                    style: zen.label(color: zen.textMuted),
                  ),
                ),
                TextButton.icon(
                  key: Key('flat-add-${kind.name}'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                  ),
                  onPressed: () =>
                      unawaited(showAddFlatItem(context, service, kind)),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: Text(t('Dodaj')),
                ),
              ],
            ),
          ),
          if (items.isEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: ZenLook.of(
                context,
              ).panel(zen, radius: 18, sunken: true),
              child: Row(
                children: <Widget>[
                  Icon(flatItemIcon(kind), color: zen.textMuted, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      empty,
                      style: TextStyle(color: zen.textMuted, fontSize: 13.5),
                    ),
                  ),
                ],
              ),
            ),
          for (final FlatItem i in items)
            FlatItemCard(
              kind: kind,
              text: i.text,
              meta: kind == FlatItemKind.invite
                  ? _inviteLine(i, service.signupsFor(i.id))
                  : null,
              trailing: <Widget>[
                if (kind == FlatItemKind.invite)
                  IconButton(
                    tooltip: t('Zaproś osoby w pobliżu (Bluetooth)'),
                    color: flatItemTone(zen, kind),
                    icon: const Icon(Icons.bluetooth_audio_rounded),
                    onPressed: () => onWave(i),
                  ),
                IconButton(
                  tooltip: t('Usuń'),
                  color: zen.textMuted,
                  icon: const Icon(Icons.delete_outline_rounded),
                  onPressed: () => unawaited(service.removeItem(i.id)),
                ),
              ],
            ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        section(
          FlatItemKind.invite,
          t('Zapraszamy'),
          t('Na kawę, grilla, planszówki…'),
        ),
        section(
          FlatItemKind.offer,
          t('Oferujemy'),
          t('Pożyczę drabinę, podleję kwiaty…'),
        ),
        section(
          FlatItemKind.need,
          t('Potrzebujemy'),
          t('Pomoc przy wnoszeniu, opieka nad kotem…'),
        ),
      ],
    );
  }

  static String _inviteLine(FlatItem i, List<FlatSignup> signups) {
    final List<String> parts = <String>[
      if (i.at != null) flatDate(i.at!),
      if (i.seats > 0)
        t('miejsca: {taken}/{seats}', {'taken': i.taken, 'seats': i.seats})
      else
        t('zapisani: {count}', {'count': i.taken}),
      if (signups.isNotEmpty)
        signups
            .map(
              (FlatSignup s) => s.count > 1 ? '${s.name} ×${s.count}' : s.name,
            )
            .join(', '),
    ];
    return parts.join(' · ');
  }
}

/// Adds an invitation, offer or need, with ready-made ideas.
Future<void> showAddFlatItem(
  BuildContext context,
  NeighborsService service,
  FlatItemKind kind,
) async {
  final TextEditingController text = TextEditingController();
  final TextEditingController seats = TextEditingController();
  DateTime? at;
  final List<String> ideas = switch (kind) {
    FlatItemKind.invite => kFlatInviteIdeas,
    FlatItemKind.offer => kFlatOfferIdeas,
    FlatItemKind.need => kFlatNeedIdeas,
  };
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => StatefulBuilder(
      builder: (BuildContext context, StateSetter set) {
        final ZenColors zen = ZenColors.of(context);
        return AlertDialog(
          title: Text(switch (kind) {
            FlatItemKind.invite => t('Zaproszenie'),
            FlatItemKind.offer => t('Oferujemy'),
            FlatItemKind.need => t('Potrzebujemy'),
          }),
          content: SizedBox(
            width: 400,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(t('POMYSŁY'), style: zen.label(color: zen.textMuted)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      for (final String idea in ideas)
                        ActionChip(
                          avatar: Icon(flatItemIcon(kind), size: 16),
                          label: Text(idea),
                          onPressed: () => set(() => text.text = idea),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('flat-item-text'),
                    controller: text,
                    maxLength: 300,
                    minLines: 1,
                    maxLines: 2,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: t('Treść'),
                      hintText: t('Wybierz pomysł albo napisz swój'),
                    ),
                  ),
                  if (kind == FlatItemKind.invite) ...<Widget>[
                    const SizedBox(height: 4),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.event_rounded),
                      label: Text(
                        at == null
                            ? t('Wybierz termin')
                            : flatDate(at!.millisecondsSinceEpoch),
                      ),
                      onPressed: () async {
                        final DateTime now = DateTime.now();
                        final DateTime? day = await showDatePicker(
                          context: context,
                          initialDate: now.add(const Duration(days: 2)),
                          firstDate: now,
                          lastDate: now.add(const Duration(days: 180)),
                        );
                        if (day == null || !context.mounted) {
                          return;
                        }
                        final TimeOfDay? t = await showTimePicker(
                          context: context,
                          initialTime: const TimeOfDay(hour: 18, minute: 0),
                        );
                        set(
                          () => at = DateTime(
                            day.year,
                            day.month,
                            day.day,
                            t?.hour ?? 18,
                            t?.minute ?? 0,
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const Key('flat-item-seats'),
                      controller: seats,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: t('Liczba miejsc'),
                        helperText: t('Puste = bez limitu'),
                        prefixIcon: const Icon(Icons.event_seat_rounded),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('flat-item-save'),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t('Dodaj')),
            ),
          ],
        );
      },
    ),
  );
  if (ok == true && text.text.trim().isNotEmpty) {
    await service.addItem(
      kind,
      text.text,
      at: at?.millisecondsSinceEpoch,
      seats: int.tryParse(seats.text.trim()) ?? 0,
    );
  }
  disposeLater(text);
  disposeLater(seats);
}
