import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/qr_sticker/presentation/sticker_designer_screen.dart';
import 'package:zen/src/features/qr_sticker/presentation/zen_qr_view.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';

// A QR code scans only dark on light: the housemate's code stays on white
// paper in every theme (see ZenFixed).
const Color _paper = ZenFixed.paper;

/// The door sticker: QR, the flat's name and a line of invitation.
class FlatDoorScreen extends ConsumerStatefulWidget {
  const FlatDoorScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const FlatDoorScreen(),
    ),
  );

  @override
  ConsumerState<FlatDoorScreen> createState() => _FlatDoorScreenState();
}

class _FlatDoorScreenState extends ConsumerState<FlatDoorScreen> {
  late final TextEditingController _note;

  /// Changes when the designer closes: the preview shows its new design.
  int _designs = 0;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(
      text: ref.read(neighborsServiceProvider).doorView.note,
    );
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// "Co widzi pukający": what a knocker sees before "Wpuść".
  List<Widget> _knockerView(NeighborsService service, Color tone) {
    final FlatDoorView v = service.doorView;
    Widget option(String key, String title, bool value, FlatDoorView next) =>
        SwitchListTile(
          key: Key('flat-view-$key'),
          title: Text(title),
          value: value,
          onChanged: (_) => unawaited(service.setDoorView(next)),
        );
    return <Widget>[
      ZenSection(t('Co widzi pukający'), top: 24),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          t(
            'Zanim go wpuścicie, widzi tylko nazwę z naklejki. Zaznaczcie, '
            'co jeszcze pokazać. To samo zobaczą ci, do których zapukacie.',
          ),
          style: TextStyle(
            color: ZenColors.of(context).textSecondary,
            fontSize: 13.5,
            height: 1.4,
          ),
        ),
      ),
      ZenGroup(
        children: <Widget>[
          option('photo', t('Zdjęcie'), v.photo, v.copyWith(photo: !v.photo)),
          option(
            'names',
            t('Imiona domowników'),
            v.names,
            v.copyWith(names: !v.names),
          ),
          option(
            'items',
            t('Zaproszenia i oferty'),
            v.items,
            v.copyWith(items: !v.items),
          ),
          option('about', t('„O nas”'), v.about, v.copyWith(about: !v.about)),
        ],
      ),
      const SizedBox(height: 10),
      TextField(
        key: const Key('flat-view-note'),
        controller: _note,
        maxLength: FlatDoorView.maxNote,
        minLines: 1,
        maxLines: 3,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          labelText: t('Notka dla pukających'),
          hintText: t('Dzwonek nie działa — pukajcie'),
          prefixIcon: const Icon(Icons.sticky_note_2_outlined),
          suffixIcon: IconButton(
            key: const Key('flat-view-note-save'),
            tooltip: t('Zapisz'),
            icon: const Icon(Icons.check_rounded),
            onPressed: () {
              FocusScope.of(context).unfocus();
              unawaited(
                service.setDoorView(
                  service.doorView.copyWith(note: _note.text.trim()),
                ),
              );
            },
          ),
        ),
        onSubmitted: (String text) => unawaited(
          service.setDoorView(service.doorView.copyWith(note: text.trim())),
        ),
      ),
      if (!v.bare)
        ZenInfo(
          icon: Icons.wifi_tethering_rounded,
          tone: tone,
          text: t(
            'Tę wizytówkę drzwi wysyłają od razu, więc pukający dowie się, '
            'że któryś z Waszych telefonów jest w sieci.',
          ),
        ),
    ];
  }

  /// The sticker designer for the door's code.
  Future<void> _design(StickerSubject door) async {
    await StickerDesignerScreen.open(context, <StickerSubject>[door]);
    if (mounted) {
      setState(() => _designs++);
    }
  }

  Future<void> _newDoor(NeighborsService service) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(t('Nowy kod?')),
        content: Text(
          t(
            'Stary kod przestanie działać (np. po przeprowadzce albo gdy '
            'trafił w niepowołane ręce). Sąsiedzi, którzy już Was mają, '
            'zostają. Trzeba będzie wydrukować nową naklejkę.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Nowy kod')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.newDoor();
    }
  }

  @override
  Widget build(BuildContext context) {
    final NeighborsService service = ref.watch(neighborsServiceProvider);
    return Scaffold(
      key: const Key('flat-door-screen'),
      appBar: AppBar(title: Text(t('Kod na drzwi'))),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListenableBuilder(
            listenable: service,
            builder: (BuildContext context, Widget? _) {
              final FlatDoorCode? code = service.doorCode;
              if (code == null && service.hasFlat) {
                // The door is a node of its own; it runs with the network.
                return Center(
                  child: SingleChildScrollView(
                    child: ZenEmpty(
                      icon: Icons.door_front_door_rounded,
                      title: t('Otwieram drzwi…'),
                      text: t(
                        'Kod na drzwi pojawi się, gdy Zen połączy się z siecią.',
                      ),
                    ),
                  ),
                );
              }
              if (code == null) {
                return Center(
                  child: SingleChildScrollView(
                    child: ZenEmpty(
                      icon: Icons.home_work_rounded,
                      title: t('Najpierw profil mieszkania'),
                      text: t(
                        'Załóżcie profil w zakładce Sąsiedzi — wtedy pojawi się '
                        'tu kod na drzwi i domownicy.',
                      ),
                    ),
                  ),
                );
              }
              // A link, so a plain camera reaches the /m page; Zen reads both.
              final String qr = code.toLink();
              final StickerSubject door = StickerSubject(
                kind: StickerKind.door,
                data: qr,
                label: t('Kod na drzwi'),
                name: code.name,
              );
              final ZenColors zen = ZenColors.of(context);
              final Color tone = neighborsTone(zen);
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: <Widget>[
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: ShapeDecoration(
                      shape: ZenLook.of(context).panelShape(zen, radius: 26),
                      gradient: LinearGradient(
                        colors: <Color>[
                          Color.alphaBlend(
                            tone.withValues(alpha: 0.22),
                            zen.surfaceSunk,
                          ),
                          zen.surfaceSunk,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 300),
                        child: AspectRatio(
                          aspectRatio: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              boxShadow: ZenLook.of(
                                context,
                              ).lift(zen, radius: 18),
                            ),
                            child: Semantics(
                              image: true,
                              label: t('Podgląd naklejki z kodem QR'),
                              child: StoredStickerPreview(
                                key: ValueKey<String>('$qr $_designs'),
                                subject: door,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    key: const Key('flat-door-save'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: () => unawaited(_design(door)),
                    icon: const Icon(Icons.print_rounded),
                    label: Text(t('Zaprojektuj i wydrukuj naklejkę')),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: <Widget>[
                      OutlinedButton.icon(
                        // Cleared from the clipboard after a minute.
                        onPressed: () => unawaited(copyWithExpiry(qr)),
                        icon: const Icon(Icons.copy_rounded),
                        label: Text(t('Kopiuj kod')),
                      ),
                      OutlinedButton.icon(
                        key: const Key('flat-door-new'),
                        onPressed: () => unawaited(_newDoor(service)),
                        icon: const Icon(Icons.autorenew_rounded),
                        label: Text(t('Nowy kod')),
                      ),
                    ],
                  ),
                  ..._knockerView(service, tone),
                  const SizedBox(height: 16),
                  ZenInfo(
                    icon: Icons.shield_outlined,
                    tone: tone,
                    title: t('Co jest w kodzie?'),
                    text: t(
                      'Klucz mieszkania, hasło tej naklejki i adresy drzwi, pod '
                      'które pukać — osobne adresy, nie adresy żadnego z Was. '
                      'Kto go zeskanuje, puka: widzicie jego wizytówkę, a '
                      'profilami wymieniacie się dopiero po „Wpuść”. Sąsiad bez '
                      'aplikacji dostanie ją od kogoś, kto ją ma („Podaj dalej”).',
                    ),
                  ),
                  const SizedBox(height: 10),
                  ZenInfo(
                    icon: Icons.info_outline_rounded,
                    tone: tone,
                    text: t(
                      'Pukanie widzą telefony wszystkich domowników, na Androidzie '
                      'i komputerze także w tle. Gdy nikogo nie ma w sieci, '
                      'pukanie do tygodnia przechowają znajomi z Waszymi '
                      'skrzynkami. „Nowy kod” zmienia hasło naklejki i adresy '
                      'drzwi.',
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A phone asking to become a resident: its name and device, "Dołącz" or
/// "Odrzuć" (only the phone that showed the household code decides).
class FlatJoinRequestCard extends StatelessWidget {
  const FlatJoinRequestCard({
    required this.service,
    required this.request,
    super.key,
  });

  final NeighborsService service;
  final FlatJoinRequest request;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = neighborsTone(zen);
    return ZenCard(
      key: Key('flat-join-request-${request.name}'),
      tone: tone,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenIconBadge(
                icon: Icons.person_add_alt_1_rounded,
                tone: tone,
                size: 40,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t('{name} chce zostać domownikiem', {
                        'name': request.name.isEmpty ? t('Ktoś') : request.name,
                      }),
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        height: 1.3,
                      ),
                    ),
                    if (request.device.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        request.device,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                    ],
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
                key: Key('flat-join-decline-${request.name}'),
                onPressed: () => unawaited(service.declineJoin(request.id)),
                child: Text(t('Odrzuć')),
              ),
              FilledButton.tonalIcon(
                key: Key('flat-join-approve-${request.name}'),
                onPressed: () => unawaited(service.approveJoin(request.id)),
                icon: const Icon(Icons.how_to_reg_rounded, size: 18),
                label: Text(t('Dołącz')),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Residents of this flat: a one-time code a new housemate scans, the
/// phones asking to join, first names, removing a phone, and leaving.
class FlatHomeScreen extends ConsumerStatefulWidget {
  const FlatHomeScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const FlatHomeScreen(),
    ),
  );

  @override
  ConsumerState<FlatHomeScreen> createState() => _FlatHomeScreenState();
}

class _FlatHomeScreenState extends ConsumerState<FlatHomeScreen> {
  /// The household code shown now (one-time, a few minutes).
  FlatHomeCode? _code;

  /// "Twoje imię w mieszkaniu": what housemates and neighbours see.
  Future<void> _rename(NeighborsService service) async {
    final TextEditingController name = TextEditingController(
      text: service.myName,
    );
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        title: Text(t('Twoje imię w mieszkaniu')),
        content: SizedBox(
          width: 400,
          child: TextField(
            key: const Key('flat-my-name'),
            controller: name,
            maxLength: 40,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              helperText: t('Tak podpisujesz wiadomości do sąsiadów.'),
              helperMaxLines: 3,
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
    final String text = name.text;
    disposeLater(name);
    if (ok == true) {
      await service.setMyName(text);
    }
  }

  Future<void> _moveOut(NeighborsService service) async {
    final TextEditingController place = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Przeprowadzka')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                t(
                  'Kod na drzwiach przestanie działać, a sąsiedzi dostaną '
                  'informację, że się wyprowadziliście, i znikną z Waszej '
                  'listy. Zaproszenia i oferty też znikną. Zostajecie Wy: '
                  'nazwa, domownicy i „O nas”. Nowi lokatorzy założą własny '
                  'profil od zera.',
                ),
              ),
              TextField(
                key: const Key('flat-new-place'),
                controller: place,
                maxLength: 80,
                decoration: InputDecoration(
                  labelText: t('Nowe miejsce (można później)'),
                  prefixIcon: const Icon(Icons.apartment_rounded),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('flat-move-out-ok'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Przeprowadzamy się')),
          ),
        ],
      ),
    );
    final String newPlace = place.text;
    disposeLater(place);
    if (ok == true) {
      await service.moveOut(newPlace: newPlace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Gotowe. Zdejmijcie starą naklejkę; nową wydrukujecie '
                'w „Kod na drzwi”.',
              ),
            ),
          ),
        );
      }
    }
  }

  /// Votes to remove a phone whose person will not leave by themselves.
  Future<void> _remove(
    NeighborsService service,
    String member,
    String name,
  ) async {
    final int needed = service.votesNeeded(member);
    final bool two = (service.profile?.members.length ?? 0) == 2;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        scrollable: true,
        icon: Icon(
          Icons.person_remove_rounded,
          color: ZenColors.of(context).danger,
        ),
        title: Text(t('Odłączyć „{name}”?', {'name': name})),
        content: Text(
          two
              ? t(
                  'Poprosimy „{name}” o zgodę. Jeśli nie odpowie w ciągu 7 '
                  'dni, telefon zostanie odłączony, a mieszkanie dostanie '
                  'nowy klucz i nowy kod na drzwi.',
                  {'name': name},
                )
              : tn(
                  needed,
                  one:
                      'Gdy zgodzi się większość pozostałych domowników '
                      '(wystarczy Twój głos), mieszkanie dostanie nowy klucz i nowy '
                      'kod na drzwi, a ten telefon zostanie bez dostępu. Sąsiedzi '
                      'dostaną informację. Starą naklejkę trzeba będzie wymienić.',
                  few:
                      'Gdy zgodzi się większość pozostałych domowników '
                      '(potrzeba {n} głosów), mieszkanie dostanie nowy klucz i nowy '
                      'kod na drzwi, a ten telefon zostanie bez dostępu. Sąsiedzi '
                      'dostaną informację. Starą naklejkę trzeba będzie wymienić.',
                  many:
                      'Gdy zgodzi się większość pozostałych domowników '
                      '(potrzeba {n} głosów), mieszkanie dostanie nowy klucz i nowy '
                      'kod na drzwi, a ten telefon zostanie bez dostępu. Sąsiedzi '
                      'dostaną informację. Starą naklejkę trzeba będzie wymienić.',
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('flat-remove-ok'),
            style: FilledButton.styleFrom(
              backgroundColor: ZenColors.of(context).danger,
              foregroundColor: ZenColors.foregroundFor(
                ZenColors.of(context).danger,
              ),
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Głosuję za')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await service.voteRemove(member);
    }
  }

  Future<void> _leave(NeighborsService service) async {
    // The last resident takes the whole flat with them.
    final bool last = (service.profile?.members.length ?? 0) <= 1;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        return AlertDialog(
          scrollable: true,
          key: const Key('flat-leave-dialog'),
          icon: Icon(Icons.logout_rounded, color: zen.danger, size: 32),
          title: Text(t('Odłączyć ten telefon?')),
          content: Text(
            last
                ? t(
                    'To ostatni telefon tego mieszkania. Po odłączeniu '
                    'profil mieszkania, lista sąsiadów i wiadomości od nich '
                    'znikną. Tego nie da się cofnąć.',
                  )
                : t(
                    'Ten telefon przestanie być domownikiem (np. ktoś się '
                    'wyprowadza sam). Pozostali zachowają profil, sąsiadów '
                    'i wiadomości, ale dostaną nowy klucz mieszkania i nowy '
                    'kod na drzwi — ten telefon nie będzie już mógł nic '
                    'podpisać ani przeczytać. Starą naklejkę trzeba będzie '
                    'wymienić.',
                  ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              key: const Key('flat-leave-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: zen.danger,
                foregroundColor: ZenColors.foregroundFor(zen.danger),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t('Odłącz')),
            ),
          ],
        );
      },
    );
    if (ok == true) {
      await service.leaveFlat();
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final NeighborsService service = ref.watch(neighborsServiceProvider);
    return Scaffold(
      key: const Key('flat-home-screen'),
      appBar: AppBar(title: Text(t('Domownicy'))),
      body: SafeArea(
        top: false,
        child: SelectionArea(
          child: ListenableBuilder(
            listenable: service,
            builder: (BuildContext context, Widget? _) {
              final FlatHomeCode? code = _code;
              final FlatProfile? p = service.profile;
              if (p == null || !service.hasFlat) {
                return Center(
                  child: SingleChildScrollView(
                    child: ZenEmpty(
                      icon: Icons.home_work_rounded,
                      title: t('Najpierw profil mieszkania'),
                      text: t(
                        'Załóżcie profil w zakładce Sąsiedzi — wtedy pojawi się '
                        'tu kod na drzwi i domownicy.',
                      ),
                    ),
                  ),
                );
              }
              final ZenColors zen = ZenColors.of(context);
              final Color tone = neighborsTone(zen);
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: <Widget>[
                  ZenHero(
                    title: t('Wasz dom w telefonach'),
                    icon: Icons.family_restroom_rounded,
                    tone: tone,
                    text: t(
                      'Każdy domownik może zmieniać profil, zapraszać i odpisywać '
                      'sąsiadom. Żeby dodać kolejnego, niech zeskanuje kod '
                      'domownika w „Sąsiedzi → Dołącz”.',
                    ),
                    actions: <Widget>[
                      ZenPill(
                        text: t('Telefony domowników: {count}', {
                          'count': p.members.length,
                        }),
                        tone: tone,
                        icon: Icons.phone_android_rounded,
                      ),
                    ],
                  ),
                  if (service.removalAsked != null)
                    Builder(
                      builder: (BuildContext context) {
                        final (String, int) asked = service.removalAsked!;
                        final String who = service.residentName(asked.$1);
                        return ZenCard(
                          key: const Key('flat-removal-asked'),
                          tone: zen.danger,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Text(
                                t('{name} chce odłączyć ten telefon', {
                                  'name': who.isEmpty ? t('Domownik') : who,
                                }),
                                style: TextStyle(
                                  color: zen.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                t('Bez odpowiedzi stanie się to {date}.', {
                                  'date': flatDate(asked.$2),
                                }),
                                style: TextStyle(
                                  color: zen.textSecondary,
                                  fontSize: 13.5,
                                  height: 1.4,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                alignment: WrapAlignment.end,
                                children: <Widget>[
                                  TextButton(
                                    key: const Key('flat-removal-refuse'),
                                    onPressed: () =>
                                        unawaited(service.refuseRemoval()),
                                    child: Text(t('Nie zgadzam się')),
                                  ),
                                  FilledButton.tonal(
                                    key: const Key('flat-removal-agree'),
                                    onPressed: () => unawaited(_leave(service)),
                                    child: Text(t('Zgadzam się')),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  for (final FlatJoinRequest r in service.joinRequests)
                    FlatJoinRequestCard(service: service, request: r),
                  ZenInfo(
                    icon: Icons.verified_user_outlined,
                    tone: tone,
                    text: t(
                      'Kod domownika działa raz, przez 10 minut. Kto go zeskanuje, '
                      'tylko prosi o dołączenie — potwierdzasz to na tym '
                      'telefonie.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (code != null)
                    Center(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Container(
                          clipBehavior: Clip.antiAlias,
                          decoration: BoxDecoration(
                            color: _paper,
                            borderRadius: BorderRadius.circular(
                              ZenLook.of(context).radius(24),
                            ),
                            border: Border.all(color: zen.outlineSoft),
                          ),
                          child: ZenQrView(
                            key: const Key('flat-home-qr'),
                            data: code.toQr(),
                            size: 272,
                          ),
                        ),
                      ),
                    )
                  else
                    FilledButton.icon(
                      key: const Key('flat-home-show'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: () =>
                          setState(() => _code = service.inviteHousemate()),
                      icon: const Icon(Icons.qr_code_rounded),
                      label: Text(t('Pokaż kod domownika')),
                    ),
                  if (code != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: <Widget>[
                        TextButton.icon(
                          key: const Key('flat-home-new'),
                          onPressed: () =>
                              setState(() => _code = service.inviteHousemate()),
                          icon: const Icon(Icons.autorenew_rounded),
                          label: Text(t('Nowy kod')),
                        ),
                        if (!Platform.isAndroid && !Platform.isIOS)
                          TextButton.icon(
                            // Gone from the clipboard after a minute.
                            onPressed: () =>
                                unawaited(copyWithExpiry(code.toQr())),
                            icon: const Icon(Icons.copy_rounded),
                            label: Text(
                              t('Kopiuj kod (dla komputera domownika)'),
                            ),
                          ),
                      ],
                    ),
                  ],
                  ZenSection(t('Telefony domowników'), top: 28),
                  ZenGroup(
                    children: <Widget>[
                      ListTile(
                        key: const Key('flat-my-name-tile'),
                        leading: Icon(Icons.badge_rounded, color: tone),
                        title: Text(t('Twoje imię w mieszkaniu')),
                        subtitle: Text(service.myName),
                        trailing: const Icon(Icons.edit_rounded),
                        onTap: () => unawaited(_rename(service)),
                      ),
                      for (final String m in p.members.keys)
                        Builder(
                          builder: (BuildContext context) {
                            final String own = service.residentKey ?? '';
                            final String known = service.residentName(m);
                            final String name = m == own
                                ? t('Ten telefon')
                                : known.isNotEmpty
                                ? known
                                : t('Telefon …{suffix}', {
                                    'suffix': m.length > 4
                                        ? m.substring(m.length - 4)
                                        : m,
                                  });
                            final Set<String> votes = service.votesFor(m);
                            final bool voted = votes.contains(own);
                            return ListTile(
                              key: Key('flat-member-$m'),
                              leading: Icon(
                                m == own
                                    ? Icons.smartphone_rounded
                                    : Icons.phone_android_rounded,
                                color: votes.isEmpty ? tone : zen.danger,
                              ),
                              title: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: service.removalDeadline(m) != null
                                  ? Text(
                                      t(
                                        'Czeka na zgodę — bez odpowiedzi '
                                        'odłączenie {date}',
                                        {
                                          'date': flatDate(
                                            service.removalDeadline(m)!,
                                          ),
                                        },
                                      ),
                                    )
                                  : votes.isEmpty
                                  ? null
                                  : Text(
                                      t(
                                        'Głosy za odłączeniem: {votes} z {needed}',
                                        {
                                          'votes': votes.length,
                                          'needed': service.votesNeeded(m),
                                        },
                                      ),
                                    ),
                              trailing: m == own
                                  ? null
                                  : voted
                                  ? TextButton(
                                      onPressed: () =>
                                          unawaited(service.withdrawVote(m)),
                                      child: Text(t('Cofnij')),
                                    )
                                  : IconButton(
                                      key: Key('flat-remove-$m'),
                                      tooltip: t('Odłącz ten telefon'),
                                      icon: Icon(
                                        Icons.person_remove_rounded,
                                        color: zen.danger,
                                      ),
                                      onPressed: () =>
                                          unawaited(_remove(service, m, name)),
                                    ),
                            );
                          },
                        ),
                    ],
                  ),
                  ZenSection(t('Zmiany'), top: 28),
                  ZenTile(
                    key: const Key('flat-move-out'),
                    icon: Icons.local_shipping_rounded,
                    tone: zen.warning,
                    title: t('Przeprowadzka'),
                    subtitle: t(
                      'Przeprowadzamy się — nowy kod, lista sąsiadów znika.',
                    ),
                    onTap: () => unawaited(_moveOut(service)),
                  ),
                  ZenTile(
                    key: const Key('flat-leave'),
                    icon: Icons.logout_rounded,
                    tone: zen.danger,
                    title: t('Odłącz ten telefon'),
                    subtitle: t('Ten telefon już tu nie mieszka.'),
                    onTap: () => unawaited(_leave(service)),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
