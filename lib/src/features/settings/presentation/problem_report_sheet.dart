import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/settings/problem_report.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// "Zgłoś problem": what happened in a few words, then the report (the
/// version, the system, what waits in the relay and the diagnostics log,
/// with no message text, names or keys) goes where the person says: to a
/// friend in Zen as a file, to a new issue on GitHub (the end of the log,
/// as much as a link carries), or into a file saved anywhere.
Future<void> showProblemReportSheet(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => const _ProblemReportSheet(),
    );

class _ProblemReportSheet extends ConsumerStatefulWidget {
  const _ProblemReportSheet();

  @override
  ConsumerState<_ProblemReportSheet> createState() =>
      _ProblemReportSheetState();
}

class _ProblemReportSheetState extends ConsumerState<_ProblemReportSheet> {
  final TextEditingController _what = TextEditingController();
  bool _busy = false;
  String? _done;

  @override
  void dispose() {
    _what.dispose();
    super.dispose();
  }

  Future<String> _report() async {
    final RelayEngine? relay = ref.read(relayEngineProvider);
    String backlog = '';
    try {
      backlog = await relay?.backlogSummary() ?? '';
    } on Object catch (error) {
      logZenWarning('The relay backlog for the report: $error');
    }
    return buildProblemReport(
      description: _what.text,
      log: await readDiagnosticsForReport(),
      backlog: backlog,
    );
  }

  String get _fileName {
    final DateTime now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'zen-raport-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}.txt';
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _done = null;
    });
    try {
      final String? said = await action();
      if (mounted) {
        setState(() => _done = said);
      }
    } on Object catch (error, stackTrace) {
      logZenError('The problem report failed', error, stackTrace);
      if (mounted) {
        setState(() => _done = t('Nie udało się. Spróbuj jeszcze raz.'));
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<String?> _toFriend() async {
    final List<FriendProfile> friends = ref
        .read(socialHubControllerProvider)
        .acceptedFriends;
    final FriendProfile? to = await showDialog<FriendProfile>(
      context: context,
      builder: (BuildContext context) => SimpleDialog(
        key: const Key('problem-report-friends'),
        title: Text(t('Komu wysłać raport?')),
        children: <Widget>[
          for (final FriendProfile f in friends)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(f),
              child: Text(ref.read(socialHubControllerProvider).nameFor(f)),
            ),
        ],
      ),
    );
    if (to == null) {
      return null;
    }
    final Uint8List bytes = Uint8List.fromList(utf8.encode(await _report()));
    await ref
        .read(socialHubControllerProvider.notifier)
        .sendLocalAttachment(
          peerAddress: to.address,
          bytes: bytes,
          fileName: _fileName,
          mimeType: 'text/plain',
          type: ChatMessageType.file,
        );
    return t('Wysłano do: {name}', <String, Object?>{
      'name': ref.read(socialHubControllerProvider).nameFor(to),
    });
  }

  Future<String?> _toGithub() async {
    final Uri url = problemIssueUrl(
      description: _what.text,
      logTail: problemLogTail(await readDiagnosticsForReport()),
    );
    final bool opened = await openWebLink(url.toString());
    return opened
        ? t(
            'Otwarto zgłoszenie na GitHubie z końcem dziennika. Cały '
            'dziennik możesz dołączyć jako plik.',
          )
        : t('Nie udało się otworzyć GitHuba.');
  }

  Future<String?> _toFile() async {
    final String report = await _report();
    final String? saved = await saveAsWritten(
      fileName: _fileName,
      dialogTitle: t('Zapisz raport'),
      mime: 'text/plain',
      write: (File file) => file.writeAsString(report, flush: true),
    );
    return saved == null
        ? null
        : t('Zapisano bez szyfrowania: {path}', <String, Object?>{
            'path': saved,
          });
  }

  @override
  Widget build(BuildContext context) {
    final bool hasFriends = ref
        .watch(socialHubControllerProvider)
        .acceptedFriends
        .isNotEmpty;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            t('Zgłoś problem'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            t(
              'Raport zawiera wersję, system i dziennik techniczny: bez '
              'treści wiadomości, imion i kluczy.',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('problem-report-what'),
            controller: _what,
            minLines: 3,
            maxLines: 6,
            decoration: InputDecoration(
              labelText: t('Co się stało?'),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          if (hasFriends)
            FilledButton.icon(
              key: const Key('problem-report-friend'),
              onPressed: _busy ? null : () => unawaited(_run(_toFriend)),
              icon: const Icon(Icons.send_rounded),
              label: Text(t('Wyślij znajomemu w Zen')),
            ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('problem-report-github'),
            onPressed: _busy ? null : () => unawaited(_run(_toGithub)),
            icon: const Icon(Icons.bug_report_outlined),
            label: Text(t('Zgłoś na GitHubie')),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('problem-report-file'),
            onPressed: _busy ? null : () => unawaited(_run(_toFile)),
            icon: const Icon(Icons.save_alt_rounded),
            label: Text(t('Zapisz plik')),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
          if (_done case final String done)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(done, key: const Key('problem-report-done')),
            ),
        ],
      ),
    );
  }
}
