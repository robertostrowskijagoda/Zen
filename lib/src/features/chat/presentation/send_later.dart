import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/chat/scheduled_messages.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// [at] as day, month and time ("05.11 20:00").
String scheduledWhen(DateTime at) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(at.day)}.${two(at.month)} ${two(at.hour)}:${two(at.minute)}';
}

/// The choices of a time to send at: in an hour, this evening at 20:00,
/// tomorrow at 8:00, or a day and hour picked. [below] goes under them
/// (what already waits, in the composer's sheet). `null`: nothing picked.
Future<DateTime?> pickSendTime(
  BuildContext context, {
  required String title,
  String? subtitle,
  List<Widget> Function(BuildContext sheet)? below,
  Listenable? listenable,
}) {
  final DateTime now = DateTime.now();
  final DateTime evening = DateTime(now.year, now.month, now.day, 20);
  final DateTime morning = DateTime(now.year, now.month, now.day + 1, 8);
  return showModalBottomSheet<DateTime>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheet) => SafeArea(
      child: ListenableBuilder(
        listenable: listenable ?? const AlwaysStoppedAnimation<int>(0),
        builder: (BuildContext context, Widget? _) => ListView(
          shrinkWrap: true,
          children: <Widget>[
            ListTile(
              title: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: subtitle == null ? null : Text(subtitle),
            ),
            ListTile(
              key: const Key('schedule-hour'),
              leading: const Icon(Icons.schedule_rounded),
              title: Text(t('Za godzinę')),
              onTap: () =>
                  Navigator.of(sheet).pop(now.add(const Duration(hours: 1))),
            ),
            if (evening.isAfter(now.add(const Duration(minutes: 30))))
              ListTile(
                key: const Key('schedule-evening'),
                leading: const Icon(Icons.nights_stay_outlined),
                title: Text(t('Dziś o 20:00')),
                onTap: () => Navigator.of(sheet).pop(evening),
              ),
            ListTile(
              key: const Key('schedule-morning'),
              leading: const Icon(Icons.wb_sunny_outlined),
              title: Text(t('Jutro o 8:00')),
              onTap: () => Navigator.of(sheet).pop(morning),
            ),
            ListTile(
              key: const Key('schedule-pick'),
              leading: const Icon(Icons.event_rounded),
              title: Text(t('Wybierz dzień i godzinę')),
              onTap: () async {
                final DateTime? day = await showDatePicker(
                  context: sheet,
                  firstDate: now,
                  lastDate: now.add(const Duration(days: 365)),
                  initialDate: now,
                );
                if (day == null || !sheet.mounted) {
                  return;
                }
                final TimeOfDay? time = await showTimePicker(
                  context: sheet,
                  initialTime: TimeOfDay.fromDateTime(
                    now.add(const Duration(hours: 1)),
                  ),
                );
                if (time == null || !sheet.mounted) {
                  return;
                }
                Navigator.of(sheet).pop(
                  DateTime(
                    day.year,
                    day.month,
                    day.day,
                    time.hour,
                    time.minute,
                  ),
                );
              },
            ),
            ...?below?.call(sheet),
          ],
        ),
      ),
    ),
  );
}

/// "Wyślij później" from a composer: [text] to [to] (a friend's address or
/// `group:<id>`) at a chosen time. The sheet also lists what already waits
/// there, each with "Anuluj", and leads to all of them. Returns whether it
/// was scheduled (the composer is then emptied by the caller).
Future<bool> scheduleFromComposer(
  BuildContext context,
  ScheduledMessagesService scheduled, {
  required String to,
  required String text,
  List<Mention> mentions = const <Mention>[],
}) async {
  await scheduled.load();
  if (!context.mounted) {
    return false;
  }
  final DateTime? at = await pickSendTime(
    context,
    title: t('Wyślij później'),
    subtitle: t(
      'Wiadomość czeka na tym urządzeniu i wychodzi o swojej '
      'porze, gdy Zen działa (albo zaraz po jego otwarciu).',
    ),
    listenable: scheduled,
    below: (BuildContext sheet) => <Widget>[
      for (final ScheduledMessage m in scheduled.waiting(to))
        ListTile(
          key: Key('scheduled-${m.id}'),
          leading: const Icon(Icons.outbox_outlined),
          title: Text(
            m.plainText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            scheduledWhen(DateTime.fromMillisecondsSinceEpoch(m.atMillis)),
          ),
          trailing: TextButton(
            onPressed: () => unawaited(scheduled.cancel(m.id)),
            child: Text(t('Anuluj')),
          ),
        ),
      if (scheduled.waiting().isNotEmpty)
        ListTile(
          key: const Key('scheduled-all'),
          leading: const Icon(Icons.list_alt_rounded),
          title: Text(t('Wszystkie zaplanowane')),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () {
            Navigator.of(sheet).pop();
            unawaited(ScheduledMessagesScreen.open(context));
          },
        ),
    ],
  );
  if (at == null || !context.mounted) {
    return false;
  }
  await scheduled.schedule(
    to: to,
    text: text,
    atMillis: at.millisecondsSinceEpoch,
    mentions: mentions,
  );
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        key: const Key('scheduled-snack'),
        content: Text(
          t('Zaplanowano na {when}', <String, Object?>{
            'when': scheduledWhen(at),
          }),
        ),
      ),
    );
  }
  return true;
}

/// On the chats list while messages wait to be sent: how many, leading to
/// all of them; nothing while none waits.
class ScheduledMessagesCard extends ConsumerWidget {
  const ScheduledMessagesCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ScheduledMessagesService scheduled = ref.watch(
      scheduledMessagesProvider,
    );
    return ListenableBuilder(
      listenable: scheduled,
      builder: (BuildContext context, Widget? _) {
        final int count = scheduled.waiting().length;
        if (count == 0) {
          return const SizedBox.shrink();
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: ZenCard(
            key: const Key('chats-scheduled'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            onTap: () => unawaited(ScheduledMessagesScreen.open(context)),
            child: Row(
              children: <Widget>[
                const Icon(Icons.outbox_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    tn(
                      count,
                      one: '{n} zaplanowana wiadomość',
                      few: '{n} zaplanowane wiadomości',
                      many: '{n} zaplanowanych wiadomości',
                    ),
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Every message that waits to be sent, the soonest first: where it goes,
/// what it says and when; each can be changed (its text, its time) or
/// taken back before it goes.
class ScheduledMessagesScreen extends ConsumerWidget {
  const ScheduledMessagesScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const ScheduledMessagesScreen(),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ScheduledMessagesService scheduled = ref.watch(
      scheduledMessagesProvider,
    );
    final SocialHubState hub = ref.watch(socialHubControllerProvider);
    String whereTo(ScheduledMessage m) {
      final String? groupId = m.groupId;
      if (groupId != null) {
        final GroupProfile? group = hub.groups[groupId];
        return group?.name ?? t('Grupa');
      }
      return hub.friendByAddress(m.to)?.displayLabel ?? m.to;
    }

    return Scaffold(
      appBar: AppBar(title: Text(t('Zaplanowane wiadomości'))),
      body: ListenableBuilder(
        listenable: scheduled,
        builder: (BuildContext context, Widget? _) {
          final List<ScheduledMessage> all = scheduled.waiting();
          if (all.isEmpty) {
            return Center(
              key: const Key('scheduled-empty'),
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  t(
                    'Nic nie czeka. Przytrzymaj przycisk wysyłania, żeby '
                    'wysłać wiadomość później.',
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            children: <Widget>[
              for (final ScheduledMessage m in all)
                ListTile(
                  key: Key('scheduled-row-${m.id}'),
                  leading: Icon(
                    m.groupId == null
                        ? Icons.person_outline_rounded
                        : Icons.groups_outlined,
                  ),
                  title: Text(
                    m.plainText,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    t('Do: {who} · {when}', <String, Object?>{
                      'who': whereTo(m),
                      'when': scheduledWhen(
                        DateTime.fromMillisecondsSinceEpoch(m.atMillis),
                      ),
                    }),
                  ),
                  trailing: PopupMenuButton<String>(
                    key: Key('scheduled-menu-${m.id}'),
                    onSelected: (String action) =>
                        unawaited(_act(context, scheduled, m, action)),
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                          // Its mentions point into the text: kept as
                          // written (a new message can say it otherwise).
                          if (m.mentions.isEmpty)
                            PopupMenuItem<String>(
                              key: const Key('scheduled-edit'),
                              value: 'edit',
                              child: Text(t('Zmień treść')),
                            ),
                          PopupMenuItem<String>(
                            key: const Key('scheduled-time'),
                            value: 'time',
                            child: Text(t('Zmień godzinę')),
                          ),
                          PopupMenuItem<String>(
                            key: const Key('scheduled-cancel'),
                            value: 'cancel',
                            child: Text(t('Anuluj wysłanie')),
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

  Future<void> _act(
    BuildContext context,
    ScheduledMessagesService scheduled,
    ScheduledMessage m,
    String action,
  ) async {
    switch (action) {
      case 'cancel':
        await scheduled.cancel(m.id);
      case 'time':
        final DateTime? at = await pickSendTime(
          context,
          title: t('Zmień godzinę'),
        );
        if (at != null) {
          await scheduled.change(m.id, atMillis: at.millisecondsSinceEpoch);
        }
      case 'edit':
        final String? text = await showDialog<String>(
          context: context,
          builder: (BuildContext dialog) => _EditScheduled(text: m.text),
        );
        if (text != null) {
          await scheduled.change(m.id, text: text);
        }
    }
  }
}

class _EditScheduled extends StatefulWidget {
  const _EditScheduled({required this.text});

  final String text;

  @override
  State<_EditScheduled> createState() => _EditScheduledState();
}

class _EditScheduledState extends State<_EditScheduled> {
  late final TextEditingController _text = TextEditingController(
    text: widget.text,
  );

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(t('Zmień treść')),
    content: TextField(
      key: const Key('scheduled-edit-field'),
      controller: _text,
      autofocus: true,
      minLines: 1,
      maxLines: 6,
      textCapitalization: TextCapitalization.sentences,
      onChanged: (_) => setState(() {}),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: Text(t('Anuluj')),
      ),
      FilledButton(
        key: const Key('scheduled-edit-save'),
        onPressed: _text.text.trim().isEmpty
            ? null
            : () => Navigator.of(context).pop(_text.text.trim()),
        child: Text(t('Zapisz')),
      ),
    ],
  );
}
