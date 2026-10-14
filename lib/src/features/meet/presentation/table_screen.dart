import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/presentation/events_screen.dart';
import 'package:zen/src/features/meet/table/table_service.dart';

const List<String> _dayNames = <String>[
  'pn',
  'wt',
  'śr',
  'cz',
  'pt',
  'sb',
  'nd',
];

/// Stół na sześć (§17.4).
class TableScreen extends ConsumerStatefulWidget {
  const TableScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const TableScreen(),
    ),
  );

  @override
  ConsumerState<TableScreen> createState() => _TableScreenState();
}

class _TableScreenState extends ConsumerState<TableScreen> {
  late final TableService _table = ref.read(tableServiceProvider);
  late final TextEditingController _city = TextEditingController(
    text: _table.myWish?.city ?? '',
  );
  late Set<int> _days = <int>{...?_table.myWish?.days};

  @override
  void dispose() {
    _city.dispose();
    super.dispose();
  }

  Future<void> _setTable() async {
    final String city = _city.text.trim();
    if (city.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Najpierw wpisz miasto.')));
      return;
    }
    final DateTime? day = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 3)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 90)),
    );
    if (day == null || !mounted) {
      return;
    }
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 19, minute: 0),
    );
    if (!mounted) {
      return;
    }
    final DateTime when = DateTime(
      day.year,
      day.month,
      day.day,
      t?.hour ?? 19,
      t?.minute ?? 0,
    );
    final List<TableWish> guests = _table.pickGuests(city, when);
    if (guests.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Na razie nikt w Twoim zasięgu nie chce na Stół w tym mieście i dniu.',
          ),
        ),
      );
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text('Zaprosić ${guests.length} osób?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final TableWish g in guests)
              Text(
                g.via == null
                    ? '• ${g.name} (Twój znajomy)'
                    : '• ${g.name}, przez ${ref.read(meetServiceProvider).host.nameOf(g.via!)}',
              ),
            const SizedBox(height: 8),
            Text(eventDate(when.millisecondsSinceEpoch)),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Anuluj'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Zaproś'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) {
      return;
    }
    final MeetEvent e = await _table.setTable(
      city: city,
      when: when,
      guests: guests,
    );
    if (mounted) {
      await EventScreen.open(context, e.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('table-screen'),
      appBar: AppBar(title: const Text('Stół na sześć')),
      body: ListenableBuilder(
        listenable: _table,
        builder: (BuildContext context, Widget? _) {
          final bool on = _table.myWish != null;
          final int nearbyCount = _table.wishes.length;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: <Widget>[
              ZenHero(
                title: 'Kolacja dla sześciu',
                icon: Icons.dinner_dining_rounded,
                tone: zenTone(zen, 2),
                text:
                    'Ty i pięcioro gości, których aplikacja dobiera sama: '
                    'znajomi Twoich znajomych, którzy też chcą tak poznawać '
                    'ludzi. Każdy zna kogoś, kto zna Ciebie — nikt nie jest '
                    'zupełnie obcy, a prawie wszyscy są nowi.',
              ),
              const ZenSection('1. Daj znać, że chcesz'),
              TextField(
                key: const Key('table-city'),
                controller: _city,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Miasto',
                  prefixIcon: Icon(Icons.location_city_rounded),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Kiedy możesz? Nic nie zaznaczysz — każdy dzień.',
                style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
              ),
              const SizedBox(height: 8),
              // The week in one row of equal toggles (never a lonely "nd"
              // wrapped to its own line).
              Row(
                children: <Widget>[
                  for (int d = 1; d <= 7; d++) ...<Widget>[
                    if (d > 1) const SizedBox(width: 6),
                    Expanded(
                      child: _DayToggle(
                        key: Key('table-day-$d'),
                        label: _dayNames[d - 1],
                        selected: _days.contains(d),
                        onTap: () => setState(() {
                          _days = <int>{..._days};
                          if (!_days.remove(d)) {
                            _days.add(d);
                          }
                        }),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              ZenGroup(
                children: <Widget>[
                  SwitchListTile(
                    key: const Key('table-wish'),
                    value: on,
                    title: const Text('Chcę na Stół na sześć'),
                    subtitle: const Text(
                      'Widzą to tylko znajomi i znajomi znajomych.',
                    ),
                    onChanged: (bool v) => unawaited(
                      _table.setWish(city: v ? _city.text : null, days: _days),
                    ),
                  ),
                ],
              ),
              const ZenSection('2. Albo zorganizuj kolację'),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: zen.surface,
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: zen.outlineSoft),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          '$nearbyCount',
                          style: zen.display(color: zenTone(zen, 2), size: 34),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            nearbyCount == 1
                                ? 'osoba w Twoim zasięgu chce na Stół'
                                : 'chętnych w Twoim zasięgu',
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const Key('table-set'),
                      onPressed: () => unawaited(_setTable()),
                      icon: const Icon(Icons.dinner_dining_rounded),
                      label: const Text('Zorganizuj stół'),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Wybierzesz dzień, a Zen zaprosi 5 gości tak, żeby jak '
                      'najmniej się znali.',
                      style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One day of the week to tick.
class _DayToggle extends StatelessWidget {
  const _DayToggle({
    required this.label,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final BorderRadius r = BorderRadius.circular(14);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? zen.accent : zen.surfaceRaised,
        borderRadius: r,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: Container(
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(
                color: selected ? zen.accent : zen.outlineSoft,
              ),
            ),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? zen.onAccent : zen.textPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
