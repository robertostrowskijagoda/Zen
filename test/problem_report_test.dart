import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/features/settings/problem_report.dart';

// "Zgłoś problem": the report and the link to a new issue on GitHub.
void main() {
  test('the report names the version, what happened, the relay and the '
      'log', () {
    final String report = buildProblemReport(
      description: 'Wiadomość nie doszła',
      log: 'INFO  start\nWARN  relay\n',
      backlog: 'Relay backlog: 2 waiting',
      now: DateTime(2026, 11, 5, 12),
    );
    expect(report, contains('Version: $kAppVersion ($kAppBuild)'));
    expect(report, contains('Wiadomość nie doszła'));
    expect(report, contains('Relay backlog: 2 waiting'));
    expect(report, endsWith('WARN  relay\n'));
  });

  test('the issue link fills the bug form and stays short', () {
    final String log = List<String>.generate(
      2000,
      (int i) => 'INFO  line $i',
    ).join('\n');
    final String tail = problemLogTail(log);
    expect(tail.length, lessThanOrEqualTo(kProblemLinkLogChars));
    expect(tail, endsWith('line 1999'));
    expect(tail, startsWith('INFO  line'), reason: 'cut at a line');
    final Uri url = problemIssueUrl(
      description: 'Nie dzwoni\nszczegóły',
      logTail: tail,
    );
    expect(url.host, 'github.com');
    expect(url.queryParameters['template'], 'bug.yml');
    expect(url.queryParameters['title'], 'Nie dzwoni');
    expect(url.queryParameters['version'], '$kAppVersion ($kAppBuild)');
    expect(url.queryParameters['logs'], tail);
    expect(url.toString().length, lessThan(8000));
  });
}
