import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/neighbors/presentation/neighbors_screen.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The door sticker (§18.2): QR, the flat's name and a line of invitation.
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
  final GlobalKey _sticker = GlobalKey();
  final TextEditingController _line = TextEditingController(
    text: t('Zeskanuj — zapraszamy na kawę!'),
  );

  @override
  void dispose() {
    _line.dispose();
    super.dispose();
  }

  /// Saves the sticker as a PNG the size of A6 at 300 dpi.
  Future<void> _save() async {
    try {
      final RenderObject? object = _sticker.currentContext?.findRenderObject();
      if (object is! RenderRepaintBoundary) {
        return;
      }
      final double ratio = 1240 / object.size.width;
      final ui.Image image = await object.toImage(pixelRatio: ratio);
      final ByteData? data = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      image.dispose();
      if (data == null) {
        return;
      }
      final Uint8List bytes = data.buffer.asUint8List();
      const String name = 'naklejka-na-drzwi.png';
      String? target;
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        target = await FilePicker.platform.saveFile(
          dialogTitle: t('Zapisz naklejkę'),
          fileName: name,
        );
      } else {
        final Directory? dir = Platform.isAndroid
            ? await getExternalStorageDirectory()
            : await getApplicationDocumentsDirectory();
        if (dir != null) {
          final Directory zen = Directory('${dir.path}/Zen');
          await zen.create(recursive: true);
          target = '${zen.path}/$name';
        }
      }
      if (target == null) {
        return;
      }
      await File(target).writeAsBytes(bytes, flush: true);
      // Outside Zen's folders: the panic password deletes it too.
      await rememberExportedFile(target);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t('Zapisano: {path} — wydrukuj w formacie A6.', {'path': target}),
            ),
          ),
        );
      }
    } on Object catch (error, stack) {
      logZenError('Naklejka na drzwi', error, stack);
    }
  }

  Future<void> _newDoor(NeighborsService service) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
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
      body: ListenableBuilder(
        listenable: service,
        builder: (BuildContext context, Widget? _) {
          final FlatDoorCode? code = service.doorCode;
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
          final ZenColors zen = ZenColors.of(context);
          final Color tone = neighborsTone(zen);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
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
                  border: Border.all(color: zen.outlineSoft),
                ),
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        boxShadow: <BoxShadow>[
                          BoxShadow(
                            color: const Color(
                              0xFF000000,
                            ).withValues(alpha: 0.25),
                            blurRadius: 18,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: RepaintBoundary(
                        key: _sticker,
                        child: _Sticker(
                          name: code.name,
                          line: _line.text,
                          qr: qr,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  t('Podgląd naklejki (A6)'),
                  style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _line,
                maxLength: 60,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: t('Hasło na naklejce'),
                  hintText: t('Zeskanuj — zapraszamy na kawę!'),
                  prefixIcon: const Icon(Icons.edit_rounded),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                key: const Key('flat-door-save'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: () => unawaited(_save()),
                icon: const Icon(Icons.print_rounded),
                label: Text(t('Zapisz naklejkę')),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  OutlinedButton.icon(
                    // Cleared from the clipboard after a minute (§14.1).
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
              const SizedBox(height: 16),
              ZenInfo(
                icon: Icons.shield_outlined,
                tone: tone,
                title: t('Co jest w kodzie?'),
                text: t(
                  'Klucz mieszkania, hasło tej naklejki i jeden adres, pod '
                  'który pukać — nie lista Waszych kont. Kto go zeskanuje, '
                  'wysyła Wam swój profil mieszkania i dostaje Wasz. Sąsiad '
                  'bez aplikacji dostanie ją od kogoś, kto ją ma („Podaj '
                  'dalej”).',
                ),
              ),
              if (!code.dedicated) ...<Widget>[
                const SizedBox(height: 10),
                ZenInfo(
                  icon: Icons.info_outline_rounded,
                  tone: tone,
                  text: t(
                    'Adres w kodzie to adres tego telefonu (telefonu od '
                    'drzwi): kto zeskanuje naklejkę, może go zobaczyć. '
                    '„Nowy kod” zmienia hasło naklejki, ale nie ten adres.',
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Sticker extends StatelessWidget {
  const _Sticker({required this.name, required this.line, required this.qr});

  final String name;
  final String line;
  final String qr;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    const Color ink = Color(0xFF151515);
    // A printed sticker: it ignores the phone's text size.
    return MediaQuery.withNoTextScaling(
      child: Container(
        width: 300,
        // A6 is 105 × 148 mm.
        height: 300 * 148 / 105,
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
        decoration: BoxDecoration(
          color: const Color(0xFFFFFFFF),
          border: Border.all(color: const Color(0x22000000)),
        ),
        child: Column(
          children: <Widget>[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F1F1),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.door_front_door_rounded,
                    size: 13,
                    color: Color(0xFF555555),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    t('SĄSIEDZI'),
                    style: const TextStyle(
                      color: Color(0xFF555555),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              name,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: zen.display(color: ink, size: 26, weight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: QrImageView(
                data: qr,
                backgroundColor: const Color(0xFFFFFFFF),
                padding: EdgeInsets.zero,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              line,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: ink,
                fontSize: 18,
                fontWeight: FontWeight.w600,
                height: 1.25,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t('Zen · sąsiedzi'),
              style: const TextStyle(color: Color(0xFF8A8A8A), fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

/// Residents of this flat (§18.1): the QR a new housemate scans — only
/// inside the flat, because it carries the flat's key — and leaving.
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
  bool _show = false;

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
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        icon: Icon(
          Icons.person_remove_rounded,
          color: ZenColors.of(context).danger,
        ),
        title: Text(t('Odłączyć „{name}”?', {'name': name})),
        content: Text(
          tn(
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
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Odłączyć ten telefon?')),
        content: Text(
          t(
            'Ten telefon przestanie być domownikiem (np. ktoś się wyprowadza '
            'sam). Pozostali zachowają profil, sąsiadów i wiadomości. Jeśli '
            'to ostatni telefon, profil zniknie.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Opuść')),
          ),
        ],
      ),
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
      body: ListenableBuilder(
        listenable: service,
        builder: (BuildContext context, Widget? _) {
          final FlatHomeCode? code = service.homeCode;
          final FlatProfile? p = service.profile;
          if (code == null || p == null) {
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
                  'sąsiadom. Żeby dodać kolejnego, niech zeskanuje ten kod '
                  'w „Sąsiedzi → Dołącz”.',
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
              ZenInfo(
                icon: Icons.warning_amber_rounded,
                tone: zen.danger,
                text: t(
                  'Pokazuj go tylko w mieszkaniu: kto go zeskanuje, staje się '
                  'domownikiem.',
                ),
              ),
              const SizedBox(height: 12),
              if (_show)
                Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFFFF),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: zen.outlineSoft),
                      ),
                      child: QrImageView(
                        key: const Key('flat-home-qr'),
                        data: code.toQr(),
                        size: 240,
                        backgroundColor: const Color(0xFFFFFFFF),
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
                  onPressed: () => setState(() => _show = true),
                  icon: const Icon(Icons.qr_code_rounded),
                  label: Text(t('Pokaż kod domownika')),
                ),
              if (_show && !Platform.isAndroid && !Platform.isIOS) ...<Widget>[
                const SizedBox(height: 8),
                Center(
                  child: TextButton.icon(
                    // The household key: gone from the clipboard after a
                    // minute (§14.1).
                    onPressed: () => unawaited(copyWithExpiry(code.toQr())),
                    icon: const Icon(Icons.copy_rounded),
                    label: Text(t('Kopiuj kod (dla komputera domownika)')),
                  ),
                ),
              ],
              ZenSection(t('Telefony domowników'), top: 28),
              ZenGroup(
                children: <Widget>[
                  for (final String m in p.members)
                    Builder(
                      builder: (BuildContext context) {
                        final String own = PeerShareCodec.normalizeAddress(
                          service.host.ownAddress(),
                        );
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
                          subtitle: votes.isEmpty
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
    );
  }
}
