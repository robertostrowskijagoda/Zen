import 'dart:io';

import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// The GitHub page of a new bug report (the form `.github/ISSUE_TEMPLATE/
/// bug.yml`), filled with [description], the version, the device and
/// [logTail].
Uri problemIssueUrl({required String description, required String logTail}) =>
    Uri.https(
      'github.com',
      '/robertostrowskijagoda/Zen/issues/new',
      <String, String>{
        'template': 'bug.yml',
        'title': description.trim().isEmpty
            ? 'Problem in Zen $kAppVersion'
            : _firstLine(description),
        'what': description.trim(),
        'version': '$kAppVersion ($kAppBuild)',
        'device': problemDeviceLine(),
        'logs': logTail,
      },
    );

/// "Android 15 (…)", "Windows 11 …": the system the report comes from.
String problemDeviceLine() =>
    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';

/// The most of the log a link to a new issue carries: GitHub refuses
/// longer addresses; the whole log goes into the saved or sent report.
const int kProblemLinkLogChars = 4000;

/// The end of [log], at most [maxChars], cut at a line.
String problemLogTail(String log, {int maxChars = kProblemLinkLogChars}) {
  if (log.length <= maxChars) {
    return log;
  }
  final String tail = log.substring(log.length - maxChars);
  final int line = tail.indexOf('\n');
  return line < 0 ? tail : tail.substring(line + 1);
}

/// The whole report: what the person wrote, the version and the system,
/// what waits in the relay ([backlog]) and the diagnostics log, which
/// holds no message text, names or keys.
String buildProblemReport({
  required String description,
  required String log,
  String backlog = '',
  DateTime? now,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln('Zen problem report')
    ..writeln('Time: ${(now ?? DateTime.now()).toIso8601String()}')
    ..writeln('Version: $kAppVersion ($kAppBuild)')
    ..writeln('System: ${problemDeviceLine()}');
  if (description.trim().isNotEmpty) {
    out
      ..writeln()
      ..writeln('What happened:')
      ..writeln(description.trim());
  }
  if (backlog.isNotEmpty) {
    out
      ..writeln()
      ..writeln(backlog);
  }
  out
    ..writeln()
    ..writeln('--- Diagnostics log ---')
    ..write(log);
  return out.toString();
}

/// The diagnostics log of both isolates, as the report carries it.
Future<String> readDiagnosticsForReport() async {
  await ZenDiagnosticsLog.settled;
  return ZenDiagnosticsLog.read();
}

String _firstLine(String text) {
  final String line = text.trim().split('\n').first.trim();
  return line.length > 80 ? '${line.substring(0, 80)}…' : line;
}
