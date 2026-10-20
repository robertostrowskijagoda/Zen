import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/alarm_sms.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_keeper.dart';
import 'package:zen/src/features/meet/presentation/alarm_audio.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';

const Color _alarmRed = Color(0xFFD32F2F);

String _clock(int millis) {
  return ZenFormat.time(DateTime.fromMillisecondsSinceEpoch(millis));
}

/// How sure a position is, shown after it: " (±12 m)", or nothing.
String _accuracy(double? accuracy) {
  if (accuracy == null) {
    return '';
  }
  final String meters = t('±{meters} m', {'meters': accuracy.round()});
  return ' ($meters)';
}

/// Keeps sending the position while this person's alarm runs (every
/// minute, for at most an hour).
final class AlarmLocationPump {
  AlarmLocationPump._();

  static Timer? _timer;
  static int _ticks = 0;

  static void start(MeetService service) {
    _timer?.cancel();
    _ticks = 0;
    _timer = Timer.periodic(const Duration(minutes: 1), (Timer t) async {
      _ticks++;
      if (service.book.ownActiveAlarm == null || _ticks > 60) {
        t.cancel();
        return;
      }
      final GeoFix? fix = await currentFix();
      if (fix != null) {
        await service.updateAlarmLocation(
          fix.lat,
          fix.lon,
          accuracy: fix.accuracy,
        );
      }
    });
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// Alarms of this person already followed by [followOwnAlarm] here.
final Set<String> _followedAlarms = <String>{};

/// What follows every alarm this person raises — the 3-second button, the
/// power-button shortcut, or one raised by the background service while the
/// app was away: the position every minute and, when chosen, sound. Once per
/// alarm.
Future<void> followOwnAlarm(MeetService service) async {
  final AlarmRecord? own = service.book.ownActiveAlarm;
  if (own == null || !_followedAlarms.add(own.id)) {
    return;
  }
  AlarmLocationPump.start(service);
  if (service.book.alarmRecordAudio) {
    AlarmAudioPump.start(service);
  }
  final GeoFix? fix = await currentFix();
  if (fix != null) {
    await service.updateAlarmLocation(fix.lat, fix.lon, accuracy: fix.accuracy);
  }
}

Widget _call112Button(BuildContext context, {bool onRed = false}) =>
    OutlinedButton.icon(
      key: const Key('alarm-call-112'),
      style: onRed
          ? OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Colors.white70, width: 1.5),
              minimumSize: const Size.fromHeight(52),
            )
          : OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52)),
      onPressed: () async {
        if (!await openDialer('112') && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t('Zadzwoń na 112 z telefonu.'))),
          );
        }
      },
      icon: const Icon(Icons.phone_rounded),
      label: Text(t('Zadzwoń na 112')),
    );

/// "Alarm" (§16.3): hold the button for 3 seconds and the closest friends
/// get it at once, with where you are.
class AlarmScreen extends ConsumerStatefulWidget {
  const AlarmScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const AlarmScreen(),
    ),
  );

  @override
  ConsumerState<AlarmScreen> createState() => _AlarmScreenState();
}

class _AlarmScreenState extends ConsumerState<AlarmScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _hold = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..addStatusListener(_onHold);
  final TextEditingController _note = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _hold.dispose();
    _note.dispose();
    super.dispose();
  }

  void _onHold(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      unawaited(_raise());
    }
  }

  Future<void> _raise() async {
    final MeetService service = ref.read(meetServiceProvider);
    setState(() => _sending = true);
    unawaited(HapticFeedback.heavyImpact());
    // Goes out at once; the position follows as soon as it is known.
    await service.raiseAlarm(note: _note.text.trim());
    await followOwnAlarm(service);
    if (mounted) {
      setState(() => _sending = false);
      _hold.reset();
    }
  }

  Future<void> _end(MeetService service) async {
    final String? pin = await _askPin(
      context,
      title: t('Jestem bezpieczny(-a)'),
      hint: t('Wpisz PIN alarmu'),
    );
    if (pin == null) {
      return;
    }
    final AlarmEndResult result = await service.endAlarm(pin);
    if (result == AlarmEndResult.wrongPin) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Zły PIN. Spróbuj jeszcze raz.'))),
        );
      }
      return;
    }
    AlarmLocationPump.stop();
    AlarmAudioPump.stop();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('Alarm odwołany.'))));
    }
  }

  /// "Zapasowy SMS": the phone numbers the alarm text can be sent to from
  /// the system SMS app when the network does not get it through.
  Future<void> _editSmsNumbers(MeetService service) async {
    final TextEditingController controller = TextEditingController(
      text: service.book.alarmSmsNumbers.join('\n'),
    );
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Zapasowy SMS')),
        content: TextField(
          key: const Key('alarm-sms-numbers'),
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          keyboardType: TextInputType.multiline,
          decoration: InputDecoration(
            labelText: t('Numery telefonów (każdy w osobnej linii)'),
            helperText: t('Do {max} numerów. Zostają tylko w tym telefonie.', {
              'max': kAlarmSmsMaxNumbers,
            }),
            prefixIcon: const Icon(Icons.sms_rounded),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('alarm-sms-save'),
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    );
    disposeLater(controller);
    if (text != null) {
      await service.setAlarmSmsNumbers(parseSmsNumbers(text));
    }
  }

  /// Opens the SMS app with the alarm text; the person presses send.
  Future<void> _sendSms(MeetService service, AlarmRecord alarm) async {
    final bool ok = await sendAlarmSms(
      numbers: service.book.alarmSmsNumbers,
      name: ref.read(eventServiceProvider).host.ownName(),
      alarm: alarm,
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(t('Nie udało się otworzyć SMS-ów.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final MeetService service = ref.watch(meetServiceProvider);
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? _) {
        final AlarmRecord? own = service.book.ownActiveAlarm;
        return Scaffold(
          key: const Key('alarm-screen'),
          appBar: ZenSectionBar(title: t('Alarm')),
          body: !service.hasAlarmPin
              ? _PinSetup(service: service)
              : own != null
              ? _activeView(context, service, own)
              : _armView(context, service),
        );
      },
    );
  }

  Widget _armView(BuildContext context, MeetService service) {
    final ZenColors zen = ZenColors.of(context);
    final List<String> to = service.alarmRecipients();
    final bool onlyClose = service.host.closeFriends().isNotEmpty;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenInfo(
          icon: to.isEmpty ? Icons.group_off_rounded : Icons.groups_rounded,
          tone: to.isEmpty ? zen.warning : zen.danger,
          title: to.isEmpty
              ? t('Nie ma do kogo wysłać')
              : t('Kto dostanie alarm'),
          text: to.isEmpty
              ? t('Nie masz jeszcze znajomych, do których alarm mógłby pójść.')
              : onlyClose
              ? t('Alarm dostaną przyjaciele: {names}.', {
                  'names': to.map(service.host.nameOf).join(', '),
                })
              : t(
                  'Nie masz nikogo oznaczonego jako przyjaciel, więc alarm '
                  'dostaną wszyscy znajomi ({count}).',
                  {'count': to.length},
                ),
        ),
        const SizedBox(height: 24),
        Center(
          // TalkBack / VoiceOver: a button with a long press (double tap and
          // hold) — the pointer-based hold below cannot be reached by them.
          child: Semantics(
            button: true,
            container: true,
            enabled: !_sending && to.isNotEmpty,
            label: _sending ? t('Alarm: wysyłam…') : t('Alarm'),
            hint: t('Przytrzymaj 3 sekundy, żeby wysłać alarm do przyjaciół'),
            onLongPress: _sending || to.isEmpty
                ? null
                : () => unawaited(_hold.forward(from: 0)),
            child: ExcludeSemantics(
              child: Listener(
                onPointerDown: (_) {
                  if (!_sending && to.isNotEmpty) {
                    unawaited(_hold.forward(from: 0));
                  }
                },
                onPointerUp: (_) {
                  if (!_hold.isCompleted) {
                    _hold.reset();
                  }
                },
                onPointerCancel: (_) {
                  if (!_hold.isCompleted) {
                    _hold.reset();
                  }
                },
                child: AnimatedBuilder(
                  animation: _hold,
                  builder: (BuildContext context, Widget? _) => SizedBox(
                    key: const Key('alarm-hold-button'),
                    width: 220,
                    height: 220,
                    child: Stack(
                      alignment: Alignment.center,
                      children: <Widget>[
                        Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: RadialGradient(
                              colors: <Color>[
                                _alarmRed.withValues(
                                  alpha: 0.10 + 0.25 * _hold.value,
                                ),
                                _alarmRed.withValues(alpha: 0),
                              ],
                            ),
                          ),
                        ),
                        SizedBox.expand(
                          child: CircularProgressIndicator(
                            value: _hold.value,
                            strokeWidth: 10,
                            strokeCap: StrokeCap.round,
                            color: _alarmRed,
                            backgroundColor: _alarmRed.withValues(alpha: 0.15),
                          ),
                        ),
                        Transform.scale(
                          scale: 1 - 0.05 * _hold.value,
                          child: Container(
                            width: 176,
                            height: 176,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: <Color>[Color(0xFFEF5350), _alarmRed],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: <BoxShadow>[
                                BoxShadow(
                                  color: _alarmRed.withValues(alpha: 0.45),
                                  blurRadius: 28,
                                  offset: const Offset(0, 10),
                                ),
                              ],
                            ),
                            alignment: Alignment.center,
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  _sending
                                      ? Icons.wifi_tethering_rounded
                                      : Icons.touch_app_rounded,
                                  color: Colors.white,
                                  size: 34,
                                ),
                                const SizedBox(height: 6),
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    _sending
                                        ? t('Wysyłam…')
                                        : t('Przytrzymaj\n3 sekundy'),
                                    textAlign: TextAlign.center,
                                    style: zen.display(
                                      color: Colors.white,
                                      size: 20,
                                      weight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          key: const Key('alarm-note'),
          controller: _note,
          maxLength: 140,
          textCapitalization: TextCapitalization.sentences,
          enableIMEPersonalizedLearning: false,
          decoration: InputDecoration(
            labelText: t('Co się dzieje? (nie trzeba)'),
            hintText: t('np. Ktoś za mną idzie'),
            prefixIcon: const Icon(Icons.edit_note_rounded),
          ),
        ),
        const SizedBox(height: 4),
        ZenGroup(
          children: <Widget>[
            SwitchListTile(
              key: const Key('alarm-audio-toggle'),
              value: service.book.alarmRecordAudio,
              secondary: const Icon(Icons.mic_rounded),
              title: Text(t('Nagrywaj dźwięk')),
              subtitle: Text(
                t(
                  'Przy alarmie telefon nagrywa otoczenie (kawałki po 20 s) '
                  'i wysyła je tym samym przyjaciołom.',
                ),
              ),
              onChanged: (bool v) => unawaited(service.setAlarmRecordAudio(v)),
            ),
            SwitchListTile(
              key: const Key('alarm-nearby-toggle'),
              value: service.book.alarmNearby,
              secondary: const Icon(Icons.bluetooth_searching_rounded),
              title: Text(t('Powiadom ludzi w pobliżu')),
              subtitle: Text(
                t(
                  'Przez Bluetooth: znajomi obok zobaczą, że to Ty, inni tylko '
                  '„ktoś w pobliżu potrzebuje pomocy”. Twój telefon odbiera '
                  'też takie alarmy od innych, nawet gdy Zen jest zamknięty.',
                ),
              ),
              onChanged: (bool v) => unawaited(service.setAlarmNearby(v)),
            ),
            if (AlarmShortcutChannel.supported)
              SwitchListTile(
                key: const Key('alarm-power-toggle'),
                value: service.book.alarmPowerButton,
                secondary: const Icon(Icons.power_settings_new_rounded),
                title: Text(t('Skrót: 5× przycisk zasilania')),
                subtitle: Text(
                  t(
                    'Naciśnij szybko 5 razy przycisk zasilania (w ciągu ok. '
                    '4 s), także przy wygaszonym ekranie i zamkniętym Zen. '
                    'Alarm pójdzie jak z przycisku, a telefon zawibruje '
                    '(długo–krótko–długo). Odwołasz go tylko PIN-em.',
                  ),
                ),
                onChanged: (bool v) =>
                    unawaited(service.setAlarmPowerButton(v)),
              ),
            ListTile(
              key: const Key('alarm-sms-setup'),
              leading: const Icon(Icons.sms_rounded),
              title: Text(t('Zapasowy SMS')),
              subtitle: Text(
                service.book.alarmSmsNumbers.isEmpty
                    ? t(
                        'Numery, do których możesz wysłać alarm SMS-em, gdy '
                        'internet nie wystarcza. Otworzy się Twoja aplikacja '
                        'do SMS-ów — wysyłasz sam(a).',
                      )
                    : service.book.alarmSmsNumbers.join(', '),
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => unawaited(_editSmsNumbers(service)),
            ),
          ],
        ),
        if (AlarmShortcutChannel.supported && service.book.alarmPowerButton)
          ZenInfo(
            icon: Icons.warning_amber_rounded,
            tone: zen.warning,
            title: t('Sprawdź ustawienia telefonu'),
            text: t(
              'Na wielu telefonach 5× przycisk zasilania włącza też '
              'systemowe „Alarmowe SOS”, które może samo zadzwonić na 112. '
              'Zdecyduj w ustawieniach Androida, czy ma działać razem z '
              'alarmem Zen. Skrót działa, dopóki Zen działa w tle; po '
              'restarcie telefonu z hasłem do Zen — dopiero po '
              'odblokowaniu aplikacji.',
            ),
          ),
        const SizedBox(height: 4),
        ZenInfo(
          icon: Icons.info_outline_rounded,
          tone: zenTone(zen, 1),
          title: t('Jak to działa'),
          text: t(
            'Alarm przebija tryb „nie przeszkadzać” i dzwoni u przyjaciół jak '
            'połączenie. Wysyła Twoje położenie (tylko teraz, tylko im) i '
            'odświeża je co minutę. Odwołasz go swoim PIN-em. PIN paniczny '
            'też go odwołuje na ekranie, ale przyjaciele dostają wtedy '
            'ostrzeżenie, że możesz być zmuszony(-a).',
          ),
        ),
        const SizedBox(height: 16),
        _call112Button(context),
        const SizedBox(height: 8),
        Text(
          t('To nie zastępuje 112.'),
          textAlign: TextAlign.center,
          style: TextStyle(color: zen.textMuted, fontSize: 12.5),
        ),
      ],
    );
  }

  Widget _activeView(BuildContext context, MeetService service, AlarmRecord a) {
    final ZenColors zen = ZenColors.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(26),
            gradient: const LinearGradient(
              colors: <Color>[Color(0xFFEF5350), _alarmRed],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.campaign_rounded,
                  color: Colors.white,
                  size: 28,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t('Alarm wysłany o {time}', {'time': _clock(a.at)}),
                      style: zen.display(
                        color: Colors.white,
                        size: 20,
                        weight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      a.hasLocation
                          ? t('Położenie wysłane o {time}', {
                                  'time': _clock(a.locatedAt ?? a.at),
                                }) +
                                _accuracy(a.accuracy)
                          : t('Szukam położenia…'),
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 13.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<bool>(
          valueListenable: AlarmAudioPump.recording,
          builder: (BuildContext context, bool on, Widget? _) =>
              on || a.clips.isNotEmpty
              ? Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      if (on)
                        ZenPill(
                          text: t('Nagrywam dźwięk…'),
                          tone: zen.danger,
                          icon: Icons.mic_rounded,
                        ),
                      if (a.clips.isNotEmpty)
                        ZenPill(
                          text: t('Wysłane nagrania: {count}', {
                            'count': a.clips.length,
                          }),
                          tone: zen.textSecondary,
                          icon: Icons.graphic_eq_rounded,
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
        // Who got it (§16.3): an alarm raised before confirmations existed
        // (no list of whom it went to) shows only the answers.
        if (a.sentTo.isNotEmpty) ...<Widget>[
          ZenSection(t('Kto dostał alarm')),
          _AlarmReachView(
            key: const Key('alarm-reach'),
            service: service,
            alarm: a,
          ),
        ] else ...<Widget>[
          ZenSection(t('Odpowiedzi')),
          if (a.responses.isEmpty)
            ZenCard(
              child: Row(
                children: <Widget>[
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: zen.textMuted,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      t('Jeszcze nikt nie odpowiedział.'),
                      style: TextStyle(color: zen.textSecondary),
                    ),
                  ),
                ],
              ),
            )
          else
            ZenGroup(
              children: <Widget>[
                for (final MapEntry<String, AlarmResponse> r
                    in a.responses.entries)
                  ListTile(
                    leading: Icon(
                      r.value == AlarmResponse.cant
                          ? Icons.close_rounded
                          : Icons.directions_run_rounded,
                      color: r.value == AlarmResponse.cant
                          ? zen.textMuted
                          : zen.success,
                    ),
                    title: Text(
                      service.host.nameOf(r.key),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: ZenPill(
                      text: r.value.label,
                      tone: r.value == AlarmResponse.cant
                          ? zen.textMuted
                          : zen.success,
                    ),
                  ),
              ],
            ),
        ],
        if (service.book.alarmSmsNumbers.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('alarm-sms-send'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
            onPressed: () => unawaited(_sendSms(service, a)),
            icon: const Icon(Icons.sms_rounded),
            label: Text(t('Wyślij SMS z alarmem')),
          ),
        ],
        const SizedBox(height: 20),
        FilledButton.icon(
          key: const Key('alarm-end'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            backgroundColor: zen.success,
            foregroundColor: ZenColors.foregroundFor(zen.success),
          ),
          onPressed: () => unawaited(_end(service)),
          icon: const Icon(Icons.verified_user_rounded),
          label: Text(t('Jestem bezpieczny(-a)')),
        ),
        const SizedBox(height: 10),
        _call112Button(context),
      ],
    );
  }
}

/// Who got this person's alarm (§16.3): every friend it went to, whether
/// their phone confirmed it, whether they opened it and what they answered.
/// After [confirmWithinMs] the ones without a confirmation are named, with
/// a button to send it to them again.
class _AlarmReachView extends StatefulWidget {
  const _AlarmReachView({
    required this.service,
    required this.alarm,
    super.key,
  });

  final MeetService service;
  final AlarmRecord alarm;

  /// How long a phone has to confirm before the person is told it did not.
  static const int confirmWithinMs = 60000;

  @override
  State<_AlarmReachView> createState() => _AlarmReachViewState();
}

class _AlarmReachViewState extends State<_AlarmReachView> {
  Timer? _tick;
  bool _resending = false;

  @override
  void initState() {
    super.initState();
    // The "not confirmed" hint comes on time even when nothing else changes.
    _tick = Timer.periodic(const Duration(seconds: 5), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _resend(List<String> to) async {
    setState(() => _resending = true);
    await widget.service.resendOwnAlarm(to: to);
    if (!mounted) {
      return;
    }
    setState(() => _resending = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t('Wysłano jeszcze raz.'))));
  }

  /// Where [f] is in the list: answers first, no confirmation last.
  static int _rank(AlarmRecord a, String f) => switch (a.reachOf(f)) {
    AlarmReach.answered => a.responses[f] == AlarmResponse.cant ? 3 : 0,
    AlarmReach.seen => 1,
    AlarmReach.delivered => 2,
    AlarmReach.sent => 4,
  };

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final MeetService service = widget.service;
    final AlarmRecord a = widget.alarm;
    final bool overdue = service.now - a.at >= _AlarmReachView.confirmWithinMs;
    final List<String> people =
        <String>[
          ...a.sentTo,
          // Answers from friends it did not go to (heard nearby).
          for (final String f in a.responses.keys)
            if (!a.sentTo.contains(f)) f,
        ]..sort((String x, String y) {
          final int byRank = _rank(a, x).compareTo(_rank(a, y));
          return byRank != 0
              ? byRank
              : service.host.nameOf(x).compareTo(service.host.nameOf(y));
        });
    final int total = a.sentTo.length;
    final int delivered = a.deliveredCount;
    final int seen = a.sentTo.where((String f) {
      final AlarmReach r = a.reachOf(f);
      return r == AlarmReach.seen || r == AlarmReach.answered;
    }).length;
    final List<String> missing = a.unconfirmed;
    final bool allIn = total > 0 && delivered == total;
    final Color summaryTone = allIn
        ? zen.success
        : overdue && missing.isNotEmpty
        ? zen.warning
        : zen.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenCard(
          tone: summaryTone,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ZenIconBadge(
                    icon: allIn ? Icons.done_all_rounded : Icons.send_rounded,
                    tone: summaryTone,
                    size: 40,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t('Doręczono {delivered} z {total}', {
                            'delivered': delivered,
                            'total': total,
                          }),
                          key: const Key('alarm-reach-summary'),
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 20,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t('Zobaczyło: {seen} · Odpowiedziało: {answered}', {
                            'seen': seen,
                            'answered': a.responses.length,
                          }),
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
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: total == 0 ? 0 : delivered / total,
                  minHeight: 6,
                  color: allIn ? zen.success : summaryTone,
                  backgroundColor: zen.surfaceSunk,
                ),
              ),
            ],
          ),
        ),
        ZenGroup(
          children: <Widget>[
            for (final String f in people) _tile(zen, service, a, f, overdue),
          ],
        ),
        if (overdue && missing.isNotEmpty) ...<Widget>[
          ZenInfo(
            key: const Key('alarm-not-confirmed'),
            icon: Icons.signal_wifi_off_rounded,
            tone: zen.warning,
            title: t('Nie dotarło do: {names}', {
              'names': missing.map(service.host.nameOf).join(', '),
            }),
            text: t(
              'Ich telefony nie potwierdziły alarmu — mogą być wyłączone, '
              'bez internetu albo mieć starszą wersję Zen. Wyślij jeszcze '
              'raz, a jeśli możesz, zadzwoń do nich lub napisz SMS.',
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const Key('alarm-resend'),
              onPressed: _resending ? null : () => unawaited(_resend(missing)),
              icon: const Icon(Icons.refresh_rounded),
              label: Text(
                missing.length == 1
                    ? t('Wyślij jeszcze raz')
                    : t('Wyślij do nich jeszcze raz'),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// One friend: an icon for how far it got, their name, the steps with
  /// times, and their answer.
  Widget _tile(
    ZenColors zen,
    MeetService service,
    AlarmRecord a,
    String f,
    bool overdue,
  ) {
    final AlarmResponse? answer = a.responses[f];
    final AlarmDelivery? d = a.deliveries[f];
    final int? gotAt = d?.got;
    final int? seenAt = d?.seen;
    final (IconData icon, Color tone) = switch (a.reachOf(f)) {
      AlarmReach.answered => switch (answer) {
        AlarmResponse.calling => (Icons.phone_in_talk_rounded, zen.success),
        AlarmResponse.cant => (Icons.do_not_disturb_on_rounded, zen.textMuted),
        _ => (Icons.directions_car_rounded, zen.success),
      },
      AlarmReach.seen => (Icons.visibility_rounded, zen.success),
      AlarmReach.delivered => (Icons.check_rounded, zen.success),
      AlarmReach.sent =>
        overdue
            ? (Icons.error_outline_rounded, zen.warning)
            : (Icons.schedule_rounded, zen.textMuted),
    };
    final List<String> steps = <String>[
      if (gotAt != null) t('✓ doręczony {time}', {'time': _clock(gotAt)}),
      if (seenAt != null) t('👁 zobaczył(a) {time}', {'time': _clock(seenAt)}),
    ];
    final String status = steps.isNotEmpty
        ? steps.join(' · ')
        : answer != null
        ? t('✓ doręczony')
        : overdue
        ? t('brak potwierdzenia')
        : t('wysłany, czekam na potwierdzenie…');
    return ListTile(
      key: Key('alarm-reach-$f'),
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tone.withValues(alpha: 0.14),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: tone, size: 20),
      ),
      title: Text(
        service.host.nameOf(f),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        status,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: answer == null && steps.isEmpty && overdue
              ? zen.warning
              : zen.textSecondary,
        ),
      ),
      trailing: answer == null
          ? null
          : ZenPill(
              text: switch (answer) {
                AlarmResponse.coming => t('🚗 jedzie'),
                AlarmResponse.calling => t('📞 dzwoni'),
                AlarmResponse.cant => t('nie może'),
              },
              tone: answer == AlarmResponse.cant ? zen.textMuted : zen.success,
            ),
    );
  }
}

class _PinSetup extends StatefulWidget {
  const _PinSetup({required this.service});

  final MeetService service;

  @override
  State<_PinSetup> createState() => _PinSetupState();
}

class _PinSetupState extends State<_PinSetup> {
  final TextEditingController _a = TextEditingController();
  final TextEditingController _b = TextEditingController();
  final TextEditingController _p = TextEditingController();
  final TextEditingController _q = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    _p.dispose();
    _q.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String pin = _a.text.trim();
    final String panic = _p.text.trim();
    final RegExp digits = RegExp(r'^\d{4,8}$');
    if (!digits.hasMatch(pin) || !digits.hasMatch(panic)) {
      setState(() => _error = t('Każdy PIN to 4–8 cyfr.'));
      return;
    }
    if (pin != _b.text.trim() || panic != _q.text.trim()) {
      setState(() => _error = t('Powtórzony PIN się nie zgadza.'));
      return;
    }
    if (pin == panic) {
      setState(() => _error = t('PIN paniczny musi być inny niż zwykły.'));
      return;
    }
    await widget.service.setAlarmPin(pin, panic);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    InputDecoration deco(String label, IconData icon) => InputDecoration(
      labelText: label,
      counterText: '',
      prefixIcon: Icon(icon),
    );
    Widget field(
      String key,
      TextEditingController c,
      String label,
      IconData icon,
    ) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextField(
        key: Key(key),
        controller: c,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        decoration: deco(label, icon),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: <Widget>[
        ZenHero(
          title: t('Najpierw dwa PIN-y'),
          icon: Icons.pin_rounded,
          tone: zen.danger,
          text: t(
            'Najpierw ustaw dwa PIN-y alarmu. Zwykły odwołuje alarm '
            '(„Jestem bezpieczny”), więc napastnik nie zgasi go za Ciebie.',
          ),
        ),
        ZenSection(t('Zwykły PIN'), top: 12),
        field('alarm-pin-1', _a, t('Zwykły PIN'), Icons.lock_rounded),
        field('alarm-pin-2', _b, t('Powtórz zwykły PIN'), Icons.lock_rounded),
        ZenSection(t('PIN paniczny')),
        ZenInfo(
          icon: Icons.warning_amber_rounded,
          tone: zen.warning,
          text: t(
            'PIN paniczny wygląda tak samo — alarm znika z ekranu — ale '
            'przyjaciele dostają ostrzeżenie, że ktoś Cię zmusza. Pomyłka '
            '(inny PIN) niczego nie odwołuje, możesz wpisać jeszcze raz.',
          ),
        ),
        const SizedBox(height: 4),
        field('alarm-panic-1', _p, t('PIN paniczny'), Icons.shield_rounded),
        field(
          'alarm-panic-2',
          _q,
          t('Powtórz PIN paniczny'),
          Icons.shield_rounded,
        ),
        if (_error != null)
          ZenInfo(
            icon: Icons.error_outline_rounded,
            tone: zen.danger,
            text: _error!,
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('alarm-pin-save'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: () => unawaited(_save()),
          icon: const Icon(Icons.check_rounded),
          label: Text(t('Zapisz PIN-y')),
        ),
      ],
    );
  }
}

Future<String?> _askPin(
  BuildContext context, {
  required String title,
  required String hint,
}) {
  final TextEditingController controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: Text(title),
      content: TextField(
        key: const Key('alarm-pin-confirm'),
        controller: controller,
        autofocus: true,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 8,
        decoration: InputDecoration(
          labelText: hint,
          counterText: '',
          prefixIcon: const Icon(Icons.lock_rounded),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('alarm-pin-ok'),
          onPressed: () => Navigator.of(context).pop(controller.text.trim()),
          child: Text(t('Odwołaj alarm')),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// A friend's alarm: where they are, who is going, and answering. While it
/// is on screen with the app in front, the friend learns it was seen.
class FriendAlarmScreen extends ConsumerStatefulWidget {
  const FriendAlarmScreen({required this.alarmId, super.key});

  final String alarmId;

  static Future<void> open(NavigatorState navigator, String alarmId) =>
      navigator.push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              FriendAlarmScreen(alarmId: alarmId),
        ),
      );

  @override
  ConsumerState<FriendAlarmScreen> createState() => _FriendAlarmScreenState();
}

class _FriendAlarmScreenState extends ConsumerState<FriendAlarmScreen>
    with WidgetsBindingObserver {
  MeetService? _service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The alarm may come in after the screen (opened from a notification).
    final MeetService service = ref.read(meetServiceProvider);
    service.addListener(_markSeen);
    _service = service;
    WidgetsBinding.instance.addPostFrameCallback((_) => _markSeen());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service?.removeListener(_markSeen);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _markSeen();
    }
  }

  /// Tells the friend their alarm is on this screen (§16.3) — only with the
  /// app in front: an alarm opened while the app is away is not "seen".
  void _markSeen() {
    final MeetService? service = _service;
    final AppLifecycleState? life = WidgetsBinding.instance.lifecycleState;
    if (service == null ||
        !mounted ||
        (life != null && life != AppLifecycleState.resumed)) {
      return;
    }
    unawaitedLogged(
      service.markAlarmSeen(widget.alarmId),
      context: 'Alarm: zobaczony',
    );
  }

  @override
  Widget build(BuildContext context) {
    final MeetService service = ref.watch(meetServiceProvider);
    final String alarmId = widget.alarmId;
    return ListenableBuilder(
      listenable: service,
      builder: (BuildContext context, Widget? _) {
        final AlarmRecord? a = service.book.alarm(alarmId);
        final ZenColors zen = ZenColors.of(context);
        if (a == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: ZenEmpty(
                icon: Icons.notifications_off_rounded,
                title: t('Nie ma tego alarmu.'),
              ),
            ),
          );
        }
        final String name = service.host.nameOf(a.from);
        final AlarmResponse? mine = a.responses['self'];
        // Heard only over Bluetooth and ended by itself: nobody knows how.
        final bool expired = a.expiredNearby;
        final Color headTone = a.isActive
            ? _alarmRed
            : a.duress || expired
            ? zen.warning
            : zen.success;
        return Scaffold(
          key: const Key('friend-alarm-screen'),
          backgroundColor: a.isActive ? _alarmRed : null,
          appBar: AppBar(
            title: Text(
              a.isActive
                  ? t('ALARM')
                  : expired
                  ? t('Alarm wygasł')
                  : t('Alarm odwołany'),
            ),
            backgroundColor: a.isActive ? _alarmRed : null,
            foregroundColor: a.isActive ? Colors.white : null,
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenCard(
                padding: const EdgeInsets.all(18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ZenIconBadge(
                          icon: a.isActive
                              ? Icons.campaign_rounded
                              : expired
                              ? Icons.timer_off_rounded
                              : a.duress
                              ? Icons.warning_amber_rounded
                              : Icons.verified_user_rounded,
                          tone: headTone,
                          size: 48,
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            a.isActive
                                ? t('{name} potrzebuje pomocy', {'name': name})
                                : expired
                                ? t(
                                    'Alarm od {name} przyszedł tylko przez '
                                    'Bluetooth i wygasł. Nie wiadomo, czy '
                                    'jest bezpieczny(-a) — zadzwoń.',
                                    {'name': name},
                                  )
                                : a.duress
                                ? t(
                                    '{name} odwołał(a) alarm PIN-em panicznym '
                                    '— może być do tego zmuszony(-a)',
                                    {'name': name},
                                  )
                                : t('{name} jest bezpieczny(-a)', {
                                    'name': name,
                                  }),
                            style: zen.display(
                              color: zen.textPrimary,
                              size: 21,
                              weight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ZenPill(
                      text: t('Od {time}', {'time': _clock(a.at)}),
                      tone: headTone,
                      icon: Icons.schedule_rounded,
                    ),
                    if (a.note.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: zen.surfaceRaised,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          '„${a.note}”',
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 15,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (a.hasLocation)
                ZenTile(
                  key: const Key('friend-alarm-map'),
                  icon: Icons.place_rounded,
                  tone: zenTone(zen, 4),
                  title: t('Pokaż na mapie'),
                  subtitle:
                      '${a.lat!.toStringAsFixed(5)}, ${a.lon!.toStringAsFixed(5)}'
                      '${_accuracy(a.accuracy)}'
                      ' · ${_clock(a.locatedAt ?? a.at)}',
                  onTap: () => unawaited(openMap(a.lat!, a.lon!, label: name)),
                )
              else
                ZenTile(
                  icon: Icons.location_disabled_rounded,
                  tone: zen.textMuted,
                  title: t('Bez położenia'),
                ),
              if (a.nearby && a.isActive)
                ZenTile(
                  icon: Icons.bluetooth_rounded,
                  tone: zenTone(zen, 2),
                  title: t('Jest blisko Ciebie'),
                  subtitle: t(
                    'Alarm przyszedł przez Bluetooth — położenie dojdzie '
                    'przez sieć.',
                  ),
                ),
              for (final AlarmClip c in a.clips)
                AlarmClipTile(service: service, alarmId: a.id, clip: c),
              if (a.responses.isNotEmpty)
                ZenGroup(
                  children: <Widget>[
                    for (final MapEntry<String, AlarmResponse> r
                        in a.responses.entries)
                      ListTile(
                        title: Text(
                          r.key == 'self'
                              ? t('Ty')
                              : service.host.nameOf(r.key),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: ZenPill(
                          text: r.value.label,
                          tone: r.value == AlarmResponse.cant
                              ? zen.textMuted
                              : zen.success,
                        ),
                      ),
                  ],
                ),
              if (a.isActive) ...<Widget>[
                const SizedBox(height: 16),
                for (final AlarmResponse r in AlarmResponse.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: FilledButton(
                      key: Key('alarm-respond-${r.name}'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                        backgroundColor: mine == r
                            ? Colors.white
                            : Colors.white.withValues(alpha: 0.16),
                        foregroundColor: mine == r ? _alarmRed : Colors.white,
                        side: BorderSide(
                          color: Colors.white.withValues(
                            alpha: mine == r ? 1 : 0.5,
                          ),
                        ),
                      ),
                      onPressed: () => unawaited(service.respond(a.id, r)),
                      child: Text(r.label),
                    ),
                  ),
                const SizedBox(height: 4),
                _call112Button(context, onRed: true),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Opens a friend's new alarm on top of whatever is on screen, and re-reads
/// what the background service received while the app was away (alarms,
/// events, questions, circles, neighbours).
class AlarmWatcher extends ConsumerStatefulWidget {
  const AlarmWatcher({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AlarmWatcher> createState() => _AlarmWatcherState();
}

class _AlarmWatcherState extends ConsumerState<AlarmWatcher>
    with WidgetsBindingObserver {
  final Set<String> _shown = <String>{};
  MeetService? _service;
  NearbyService? _nearby;
  Timer? _minute;
  int _minutes = 0;

  /// The power-button shortcut (§16.3) when it comes to the app.
  StreamSubscription<void>? _powerShortcut;

  /// What the phone was last told about the shortcut (`null`: nothing yet).
  bool? _shortcutOn;

  /// The short look around now and then while the app is on screen (§15).
  NearbyKeeper? _keeper;

  /// An alarm wave heard over Bluetooth (§16.3); [device] wrote it. Only a
  /// friend's signed wave rings ([MeetService.onAlarmWave] checks).
  void _onWave(Map<dynamic, dynamic> json, String device) {
    final MeetService? service = _service;
    final NearbyService? nearby = _nearby;
    if (service == null || nearby == null) {
      return;
    }
    unawaitedLogged(
      service.onAlarmWave(
        json,
        friend: nearby.friendOfToken(json['t']),
        source: device,
      ),
      context: 'Alarm w pobliżu',
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final MeetService service = ref.read(meetServiceProvider);
    _service = service..addListener(_check);
    // Alarms to and from phones nearby go over Bluetooth (§16.3); the
    // wave carries this phone's nearby token and a signature only friends
    // can check ([MeetService.alarmWave]).
    final NearbyService nearby = ref.read(nearbyServiceProvider);
    _nearby = nearby;
    nearby.alarmWaveHandlers.add(_onWave);
    service.nearbyBroadcast = nearby.waveAround;
    // 5× the power button (§16.3): the phone counts and tells the app while
    // it runs the network itself (otherwise the background service).
    _powerShortcut = const AlarmShortcutChannel().presses.listen((_) {
      unawaitedLogged(_onPowerShortcut(), context: 'Skrót alarmu');
    });
    // Friends nearby marked met in person without the "W pobliżu" screen,
    // when allowed; the background service does it while the app is away.
    final NearbyKeeper keeper = NearbyKeeper(
      nearby: nearby,
      inService: false,
      active: () =>
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
    );
    _keeper = keeper;
    unawaitedLogged(keeper.start(), context: 'W pobliżu: rozglądanie');
    // Dating deadlines and the weekly package (§19) run while the app does.
    _minute = Timer.periodic(const Duration(minutes: 1), (_) {
      _minutes++;
      datingMinute(ref.read(datingServiceProvider), _minutes);
      pyramidMinute(ref.read(pyramidServiceProvider), _minutes);
      _followRaisedElsewhere();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _service?.removeListener(_check);
    _service?.nearbyBroadcast = null;
    _nearby?.alarmWaveHandlers.remove(_onWave);
    _minute?.cancel();
    final StreamSubscription<void>? powerShortcut = _powerShortcut;
    _powerShortcut = null;
    if (powerShortcut != null) {
      unawaited(powerShortcut.cancel());
    }
    unawaitedLogged(_keeper?.close(), context: 'W pobliżu: rozglądanie');
    _keeper = null;
    super.dispose();
  }

  /// The shortcut came here: the very alarm of the button, then the
  /// position and sound like after the button.
  Future<void> _onPowerShortcut() async {
    final MeetService? service = _service;
    if (service == null) {
      return;
    }
    final ShortcutAlarmResult result = await raiseAlarmFromShortcut(service);
    logZenMessage('Skrót alarmu w aplikacji: ${result.name}.');
    if (result == ShortcutAlarmResult.raised) {
      await followOwnAlarm(service);
    }
  }

  /// Tells the phone to count power-button presses while the person wants
  /// the shortcut. Only the person turns it off (a book not read yet must
  /// not switch off what the background service turned on).
  void _syncShortcut(MeetService service) {
    final bool on = service.book.alarmPowerButton && service.hasAlarmPin;
    final bool? was = _shortcutOn;
    if (was == on) {
      return;
    }
    _shortcutOn = on;
    if (on || was == true) {
      unawaited(const AlarmShortcutChannel().setEnabled(on));
    }
  }

  /// An alarm of this person raised while the app was away (the shortcut in
  /// the background service): the position and sound follow from here. Not
  /// right after it started — the one raising it follows it itself.
  void _followRaisedElsewhere() {
    final MeetService? service = _service;
    final AlarmRecord? own = service?.book.ownActiveAlarm;
    if (service == null || own == null || service.now - own.at < 10000) {
      return;
    }
    unawaitedLogged(followOwnAlarm(service), context: 'Alarm: położenie');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The Android background service may have taken frames meanwhile.
      unawaited(_service?.reload());
      unawaited(ref.read(eventServiceProvider).load());
      unawaited(ref.read(askServiceProvider).load());
      unawaited(ref.read(tableServiceProvider).load());
      unawaited(ref.read(circleServiceProvider).load());
      unawaited(ref.read(neighborsServiceProvider).load());
      unawaited(ref.read(datingServiceProvider).load());
      unawaited(ref.read(pyramidServiceProvider).load());
    }
  }

  void _check() {
    final MeetService? service = _service;
    if (service == null || !mounted) {
      return;
    }
    _syncShortcut(service);
    _followRaisedElsewhere();
    final NavigatorState? navigator = zenRootNavigatorKey.currentState;
    if (navigator == null) {
      return;
    }
    for (final AlarmRecord a in service.book.activeAlarmsFromFriends()) {
      if (a.responses['self'] == null && _shown.add(a.id)) {
        unawaited(FriendAlarmScreen.open(navigator, a.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
