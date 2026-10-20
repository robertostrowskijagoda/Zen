import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// "Osoby w pobliżu" (§15).
class NearbyScreen extends ConsumerStatefulWidget {
  const NearbyScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const NearbyScreen(),
    ),
  );

  @override
  ConsumerState<NearbyScreen> createState() => _NearbyScreenState();
}

class _NearbyScreenState extends ConsumerState<NearbyScreen>
    with WidgetsBindingObserver {
  late final NearbyService _nearby = ref.read(nearbyServiceProvider);
  Map<Object?, Object?> _state = const <Object?, Object?>{};
  bool _loaded = false;

  bool get _android => !kIsWeb && Platform.isAndroid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _nearby.bluetoothHandlers.add(_onBluetooth);
    unawaited(_refresh(scan: true));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _nearby.bluetoothHandlers.remove(_onBluetooth);
    unawaited(_nearby.stopScanning());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Scanning costs battery: only while this screen is really on screen.
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_refresh(scan: true));
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        unawaited(_nearby.stopScanning());
      case AppLifecycleState.inactive:
        break;
    }
  }

  void _onBluetooth(bool on) {
    if (mounted) {
      unawaited(_refresh(scan: on));
    }
  }

  Future<void> _refresh({bool scan = false}) async {
    final Map<Object?, Object?> state = await _nearby.radio.state();
    if (!mounted) {
      return;
    }
    setState(() {
      _state = state;
      _loaded = true;
    });
    if (scan && state['permitted'] == true && state['enabled'] == true) {
      // Low power: the list fills a little slower, the battery lasts.
      await _nearby.startScanning(lowPower: true);
      final MeetService meet = ref.read(meetServiceProvider);
      if (meet.book.nearbyVisible && !_nearby.visible) {
        await _nearby.setVisible(true);
      }
    }
  }

  Future<void> _allow() async {
    await _nearby.radio.requestPermissions();
    // The system dialog answers later; look again shortly.
    await Future<void>.delayed(const Duration(seconds: 2));
    await _refresh(scan: true);
  }

  Future<void> _enableBluetooth() async {
    // The system asks; the answer comes as a Bluetooth event.
    if (await _nearby.radio.requestEnable()) {
      await _refresh(scan: true);
    }
  }

  Future<void> _setVisible(bool on) async {
    await ref.read(meetServiceProvider).setNearbyVisible(on);
    await _nearby.setVisible(on);
  }

  Future<void> _wave(NearbyPerson person) async {
    final TextEditingController text = TextEditingController();
    final String? message = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Napisz do: {name}', {'name': person.pseudonym})),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ZenInfo(
              icon: Icons.privacy_tip_outlined,
              text: t(
                'Dostanie Twój pseudonim i tę wiadomość — nie Twoje konto. '
                'Możesz napisać jedną wiadomość, dopóki nie odpowie.',
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('nearby-wave-text'),
              controller: text,
              autofocus: true,
              maxLength: 300,
              minLines: 1,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              enableIMEPersonalizedLearning: false,
              decoration: InputDecoration(
                labelText: t('Wiadomość'),
                hintText: t('np. Cześć! Też tu jesteś?'),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(text.text),
            child: Text(t('Wyślij')),
          ),
        ],
      ),
    );
    disposeLater(text);
    if (message == null || message.trim().isEmpty || !mounted) {
      return;
    }
    final NearbySession? s = await _nearby.wave(person, message);
    if (!mounted) {
      return;
    }
    if (s == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Nie udało się — ta osoba mogła się oddalić.')),
        ),
      );
      return;
    }
    await NearbyChatScreen.open(context, s.id);
  }

  @override
  Widget build(BuildContext context) {
    final MeetService meet = ref.watch(meetServiceProvider);
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 0);
    return Scaffold(
      key: const Key('nearby-screen'),
      appBar: ZenSectionBar(title: t('Osoby w pobliżu')),
      body: ListenableBuilder(
        listenable: _nearby,
        builder: (BuildContext context, Widget? _) {
          if (!_android) {
            return Center(
              child: SingleChildScrollView(
                child: ZenEmpty(
                  icon: Icons.phone_android_rounded,
                  tone: tone,
                  title: t('Tylko na Androidzie'),
                  text: t(
                    'Osoby w pobliżu działają na telefonie z Androidem '
                    '(Bluetooth). Na iPhonie i na komputerze ich nie ma.',
                  ),
                ),
              ),
            );
          }
          if (!_loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_state['supported'] != true) {
            return Center(
              child: SingleChildScrollView(
                child: ZenEmpty(
                  icon: Icons.bluetooth_disabled_rounded,
                  tone: zen.warning,
                  title: t('Brak Bluetooth LE'),
                  text: t('Ten telefon nie ma Bluetooth LE.'),
                ),
              ),
            );
          }
          final List<NearbyPerson> people = _nearby.people;
          final List<NearbySession> sessions = _nearby.sessions;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenHero(
                title: t('Ludzie obok Ciebie'),
                icon: Icons.radar_rounded,
                tone: tone,
                text: t(
                  'Zobacz, kto z Zen jest teraz blisko — znajomych z imieniem, '
                  'resztę pod pseudonimem. Możesz napisać jedną wiadomość na '
                  'start.',
                ),
              ),
              if (_state['permitted'] != true)
                ZenCard(
                  tone: zen.warning,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          ZenIconBadge(
                            icon: Icons.bluetooth_rounded,
                            tone: zen.warning,
                            size: 40,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  t('Zezwól na Bluetooth'),
                                  style: TextStyle(
                                    color: zen.textPrimary,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 15.5,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  t(
                                    'Żeby widzieć ludzi obok i być widocznym. '
                                    'Zen nie używa tego do ustalania, gdzie '
                                    'jesteś.',
                                  ),
                                  style: TextStyle(
                                    color: zen.textSecondary,
                                    fontSize: 13.5,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        key: const Key('nearby-allow'),
                        onPressed: () => unawaited(_allow()),
                        icon: const Icon(Icons.check_rounded),
                        label: Text(t('Zezwól')),
                      ),
                    ],
                  ),
                )
              else if (_state['enabled'] != true)
                ZenCard(
                  tone: zen.warning,
                  child: Row(
                    children: <Widget>[
                      ZenIconBadge(
                        icon: Icons.bluetooth_disabled_rounded,
                        tone: zen.warning,
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          t('Włącz Bluetooth'),
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 15.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        key: const Key('nearby-enable-bluetooth'),
                        onPressed: () => unawaited(_enableBluetooth()),
                        child: Text(t('Włącz')),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 4),
              ZenGroup(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('nearby-visible'),
                    value: meet.book.nearbyVisible,
                    title: Text(t('Widoczny(-a) w pobliżu')),
                    subtitle: Text(
                      t(
                        'Znajomi widzą Cię z imieniem, inni jako „{name}” '
                        '(zmienia się co 15 minut, więc nikt Cię nie wyśledzi). '
                        'Telefon nadaje oszczędnie cały czas, także przy '
                        'zamkniętym Zen.',
                        {'name': _nearby.myPseudonym},
                      ),
                    ),
                    onChanged: (bool v) => unawaited(_setVisible(v)),
                  ),
                  // The setting lives in the meeting book, not in the radio.
                  ListenableBuilder(
                    listenable: meet,
                    builder: (BuildContext context, Widget? _) => SwitchListTile(
                      key: const Key('nearby-background-scan'),
                      value: meet.book.nearbyBackgroundScan,
                      title: Text(t('Rozglądaj się też w tle')),
                      subtitle: Text(
                        t(
                          'Co 5 minut telefon na 10 sekund oszczędnie sprawdza, '
                          'czy obok są znajomi, i zaznacza ich jako „spotkanych '
                          'osobiście”. Działa też przy zamkniętym Zen. Pełne '
                          'szukanie tylko na tym ekranie.',
                        ),
                      ),
                      onChanged: (bool v) =>
                          unawaited(meet.setNearbyBackgroundScan(v)),
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 20, 0, 8),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        t('W POBLIŻU'),
                        style: zen.label(color: zen.textMuted),
                      ),
                    ),
                    if (_nearby.scanning)
                      ZenPill(
                        text: t('Szukam'),
                        tone: zen.success,
                        icon: Icons.radar_rounded,
                      )
                    else
                      ZenPill(
                        text: t('Nie szukam'),
                        tone: zen.textMuted,
                        icon: Icons.pause_rounded,
                      ),
                  ],
                ),
              ),
              if (people.isEmpty)
                ZenEmpty(
                  icon: _nearby.scanning
                      ? Icons.radar_rounded
                      : Icons.bluetooth_searching_rounded,
                  tone: tone,
                  title: _nearby.scanning
                      ? t('Nikogo jeszcze nie widać')
                      : t('Nie szukam'),
                  text: _nearby.scanning
                      ? t('Szukam… Nikogo z Zen jeszcze nie widać.')
                      : t('Nie szukam (brak Bluetooth albo zgody).'),
                ),
              for (final NearbyPerson p in people)
                _personTile(meet, p, zen, tone),
              if (sessions.isNotEmpty) ...<Widget>[
                ZenSection(t('Rozmowy z pobliża')),
                for (final NearbySession s in sessions)
                  ZenTile(
                    icon: Icons.forum_rounded,
                    tone: zenTone(zen, 5),
                    title: s.pseudonym,
                    subtitle: s.lines.isEmpty ? null : s.lines.last.text,
                    onTap: () =>
                        unawaited(NearbyChatScreen.open(context, s.id)),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _personTile(
    MeetService meet,
    NearbyPerson p,
    ZenColors zen,
    Color tone,
  ) {
    final String? friend = p.friend;
    if (friend != null) {
      final bool met = meet.book.metAt(friend) != null;
      return ZenTile(
        key: Key('nearby-friend-$friend'),
        icon: Icons.person_pin_circle_rounded,
        tone: zen.success,
        title: meet.host.nameOf(friend),
        subtitle: met
            ? t('{distance} · spotkani osobiście', {
                'distance': nearbyDistance(p.rssi),
              })
            : nearbyDistance(p.rssi),
        trailing: met ? Icon(Icons.verified_rounded, color: zen.success) : null,
      );
    }
    return ZenTile(
      icon: Icons.person_outline_rounded,
      tone: tone,
      title: p.pseudonym,
      subtitle: nearbyDistance(p.rssi),
      trailing: FilledButton.tonal(
        onPressed: () => unawaited(_wave(p)),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: 14),
        ),
        child: Text(t('Napisz')),
      ),
    );
  }
}

/// A conversation with someone met nearby.
class NearbyChatScreen extends ConsumerStatefulWidget {
  const NearbyChatScreen({required this.sessionId, super.key});

  final String sessionId;

  static Future<void> open(BuildContext context, String id) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => NearbyChatScreen(sessionId: id),
        ),
      );

  @override
  ConsumerState<NearbyChatScreen> createState() => _NearbyChatScreenState();
}

class _NearbyChatScreenState extends ConsumerState<NearbyChatScreen> {
  final TextEditingController _text = TextEditingController();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _invite(NearbySession s) async {
    final String? address = s.address;
    if (address == null) {
      return;
    }
    await ref
        .read(socialHubControllerProvider.notifier)
        .sendFriendRequest(peerAddress: address, knownName: s.pseudonym);
    await ref.read(meetServiceProvider).markMet(address);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Wysłano zaproszenie. Po przyjęciu będziecie „spotkani '
              'osobiście”.',
            ),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final NearbyService nearby = ref.watch(nearbyServiceProvider);
    return ListenableBuilder(
      listenable: nearby,
      builder: (BuildContext context, Widget? _) {
        final NearbySession? s = nearby.session(widget.sessionId);
        final ZenColors zen = ZenColors.of(context);
        if (s == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: ZenEmpty(
                icon: Icons.forum_outlined,
                title: t('Rozmowa zamknięta.'),
              ),
            ),
          );
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(s.pseudonym),
            actions: <Widget>[
              PopupMenuButton<String>(
                onSelected: (String v) {
                  if (v == 'invite') {
                    unawaited(_invite(s));
                  } else if (v == 'block') {
                    nearby.block(s);
                    Navigator.of(context).pop();
                  }
                },
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  if (s.address != null)
                    PopupMenuItem<String>(
                      value: 'invite',
                      child: Text(t('Zaproś do znajomych')),
                    ),
                  PopupMenuItem<String>(
                    value: 'block',
                    child: Text(t('Zablokuj')),
                  ),
                ],
              ),
            ],
          ),
          body: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  children: <Widget>[
                    for (final NearbyLine l in s.lines)
                      Align(
                        alignment: l.mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 320),
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: l.mine ? zen.accent : zen.surfaceRaised,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(18),
                              topRight: const Radius.circular(18),
                              bottomLeft: Radius.circular(l.mine ? 18 : 6),
                              bottomRight: Radius.circular(l.mine ? 6 : 18),
                            ),
                            border: l.mine
                                ? null
                                : Border.all(color: zen.outlineSoft),
                          ),
                          child: Text(
                            l.text,
                            style: TextStyle(
                              color: l.mine ? zen.onAccent : zen.textPrimary,
                              fontSize: 14.5,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _text,
                          enabled: s.canSend,
                          enableIMEPersonalizedLearning: false,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: InputDecoration(
                            hintText: s.canSend
                                ? t('Napisz…')
                                : t('Poczekaj na odpowiedź'),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: t('Wyślij'),
                        icon: const Icon(Icons.send_rounded),
                        onPressed: s.canSend
                            ? () async {
                                final String t = _text.text;
                                _text.clear();
                                await nearby.send(s, t);
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
